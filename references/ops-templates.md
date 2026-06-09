# 运维模板

本文件包含日常使用的指令模板，供快速参考和复用。

---

## 强制规则

- 真实测试主流程必须优先使用 `scripts/ops/*.sh`。本文件中的命令只用于理解、排障和补充说明。
- 单模型 `custom` 冒烟或回归任务优先使用绝对路径入口
  `bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh ...`，把 preflight、创建容器、
  启动、等待、benchmark、报告、停止和最终报告收敛到一个稳定入口，减少 Claude Code 权限询问。
- 不要使用 `cd /public/... && bash scripts/ops/run_single_task.sh ...`，该命令形态无法匹配推荐的 Claude Code allow 规则。
- 不要使用 `SKILL_ROOT=...` 多行变量块拼接入口；正式命令必须直接以 `bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh` 开头。
- 不要使用 `DRY_RUN=1 bash ...` 或 `DRY_RUN=0 bash ...` 环境变量前缀；dry-run 必须使用脚本参数 `--dry-run`。
- `run_single_task.sh` 已内置 preflight，正式单模型 custom 流程不要单独调用 `preflight_node.sh`。
- ops 脚本失败时，应记录脚本名、参数和错误输出后停止流程，不要手写新的 SSH/Docker 长命令绕过。
- 容器内涉及 `vllm`、`torch`、`vllm bench serve` 的命令必须使用 `bash -ic`。
- benchmark 必须通过 `scripts/ops/run_bench.sh` 调用，不能直接把 `scripts/client-scripts/*.sh` 当主入口。
- 停止服务必须通过 `scripts/ops/stop_service.sh`，不能手写 `docker stop`，更不能自动执行 `docker rm`。
- stop/report 阶段失败时，只能用 `scripts/ops/recover_single_task.sh --state ...` 恢复，不要手写 SSH/Docker 回退。
- SERVICE_TIMEOUT、SERVICE_STARTED、WAITING_READY 后继续执行时，只能用
  `scripts/ops/resume_single_task.sh --state ...` 恢复 wait/bench/report/stop/final report，不要手写 `curl`、`run_bench.sh` 或造 CSV。
- 容器路径 `/mnt/skilltest/...` 与宿主机路径 `/public/home/<user>/skilltest/...` 必须同时记录；容器停止后从宿主机路径读取产物。

---

## 0. GPU / DCU 检查模板

### 海光 DCU 节点（推荐，优先使用）

# 检查 DCU 数量（hy-smi 使用 -i 显示所有 DCU）
ssh <NODE_IP> "/opt/hyhal/bin/hy-smi -i | grep -c 'DCU'"

# 检查 DCU 详情（型号、显存）
ssh <NODE_IP> "/opt/hyhal/bin/hy-smi --showid --showmeminfo vram"

# 检查 /dev/kfd 设备和 DRM 卡数量
ssh <NODE_IP> "ls /dev/kfd && ls /sys/class/drm/ | grep -c 'card[0-9]'"

# 注意：hy-smi 不支持 -L 参数（那是 nvidia-smi 的语法，hy-smi 会报 exit code 127）
# 正确用法：hy-smi（无参数）或 hy-smi -i
# 错误用法：hy-smi -L（会导致命令失败）
```

### GPU 检查容错逻辑

按以下优先级尝试，任意一种成功即确认 GPU 可用：

1. `/opt/hyhal/bin/hy-smi`（海光 DCU，无参数或 -i）
2. `rocm-smi --showid`（AMD GPU）
3. `nvidia-smi -L`（NVIDIA GPU）
4. `ls /dev/kfd && ls /sys/class/drm/ | grep -c 'card[0-9]'`（兜底：设备文件存在即认为 GPU 可用）

```bash
# 容错检查一行命令
ssh <NODE_IP> "/opt/hyhal/bin/hy-smi 2>/dev/null || rocm-smi --showid 2>/dev/null || nvidia-smi -L 2>/dev/null || (ls /dev/kfd && echo '发现 KFD 设备')"
```

---

## 1. Docker 容器创建

### 容器命名规范

**格式：** `<container_prefix>-<MMDD>-<MODEL_SHORT>-<IMAGE_PREFIX>`

**示例：** `<container_prefix>-0428-glm47int8-2540`

MODEL_SHORT 规则：
- GLM-4.7-W8A8 / GLM-4.7-Channel-INT8 → glm47int8
- GLM-5.1-Channel-INT8 → glm51int8
- GLM-4.7-W8A16 / GLM-4.7-Channel-FP8 → glm47fp8
- GLM-5.1-Channel-FP8 → glm51fp8
- GLM-4.7（未标精度，默认 bf16）→ glm47
- GLM-5.1（未标精度，默认 bf16）→ glm51

新增模型不要手写 `MODEL_SHORT`。优先调用：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh ...
```

通用推导示例：
- GLM-5-W8A8 → glm5int8
- Qwen3.5-35B → qwen35b35
- Qwen3.5-35B-W8A8 → qwen35b35int8
- Qwen2.5-72B-Instruct-W8A8 → qwen25b72int8
- DeepSeek-R1-Distill-Qwen-32B-W8A8 → dsr1distillqwenb32int8

非 GLM 注册规则：
- Qwen、DeepSeek 等非 GLM 模型必须显式传 `--port`。
- 非 GLM 不默认 `TP=8`；必须显式传 `--tp`，或从脚本中的 `-tp 2`、`--tensor-parallel-size 2`、`export TP_SIZE=2`、`export TP=2` 推导。
- 若推导出 `TP=2` 且未传 `--gpu-range`，默认 `GPU_RANGE=0,1`。
- 正式注册未参数化脚本默认失败，除非显式传 `--allow-static-server-script`。

### 基础容器创建

```bash
ssh <NODE_IP> "docker run -itd --name=<CONTAINER_NAME> \
  --privileged --network=host \
  --device=/dev/kfd --device=/dev/dri \
  --ipc=host --group-add video \
  --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  --ulimit stack=-1:-1 --ulimit memlock=-1:-1 \
  -v /public/home/<user>:/mnt \
  -v /module/:/module:ro \
  -v /public/opendas/DL_DATA/llm-models/:/model:ro \
  -v /public4/share/:/model1:ro \
  -v /public4/opendas/DL_DATA/:/model2:ro \
  -v /opt/hyhal:/opt/hyhal:ro \
  <IMAGE> bash"
```

### 创建前检查同名容器

```bash
ssh <NODE_IP> "docker ps -a --filter 'name=<CONTAINER_NAME>' --format '{{.Names}}'"
```

---

## 2. 服务启动标准模板

必须使用 `bash -ic` 复现交互式容器环境。

### 标准启动命令

```bash
ssh <NODE_IP> "docker exec -w /mnt/.claude/skills/vllm-perf-validation-single <CONTAINER_NAME> bash -ic '
# 日志写入统一工作区路径
WORK_DIR=/mnt/skilltest/vllm-perf-validation-single/work_dirs/<MODEL>-<TEST_MODE>-<DATE>-<CONTAINER_NAME>
mkdir -p \"\${WORK_DIR}/logs\"

LOG=\${WORK_DIR}/logs/<MODEL_SHORT>-<MMDD>-vllm-server.log
PID=\${WORK_DIR}/logs/<MODEL_SHORT>-<MMDD>-vllm-server.pid

rm -f \"\$LOG\" \"\$PID\"

nohup bash /mnt/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/<SERVER_SCRIPT> > \"\$LOG\" 2>&1 &
echo \$! > \"\$PID\"

sleep 10

echo === PID ===
cat \"\$PID\" || true

echo === PROC ===
ps aux | grep -E \"vllm|ray|python|APIServer\" | grep -v grep || true

echo === LOG_TAIL ===
tail -120 \"\$LOG\" || true
'"
```

### 禁止使用的启动方式

- `docker exec -d <CONTAINER> bash <SCRIPT>`
- `docker exec <CONTAINER> bash -lc 'bash <SCRIPT>'`
- `ssh <NODE> "docker exec <CONTAINER> bash <SCRIPT> &"`

原因：`docker exec -d` 返回成功不代表服务成功；`bash -lc` 可能缺失 DTK/HYHAL 环境。

---

## 3. 工作路径创建

### 统一工作路径结构

**格式：** `<MODEL>-<TEST_MODE>-<DATE>-<CONTAINER_NAME>/`

**示例：**
```
/public/home/<user>/skilltest/vllm-perf-validation-single/work_dirs/GLM-4.7-W8A8-serial-full-20260515-<container_prefix>-0428-glm47int8-2540/
```

**子目录结构：**
```
<WORK_DIR>/
├── logs/                    # 服务日志和测试日志
├── csvs/                    # CSV 结果（每个测试模式一个子目录）
│   ├── full/
│   ├── pchit/
│   ├── engin/
│   └── custom/
├── commands_backup.txt      # 命令备份
└── state.json               # 运行状态
```

### 创建工作路径命令

```bash
# 在容器内创建统一工作路径
docker exec <CONTAINER_NAME> bash -ic '
export WORK_DIR="/mnt/skilltest/vllm-perf-validation-single/work_dirs/<MODEL>-<TEST_MODE>-<DATE>-<CONTAINER_NAME>"
mkdir -p "${WORK_DIR}/logs" "${WORK_DIR}/csvs/full" "${WORK_DIR}/csvs/pchit" "${WORK_DIR}/csvs/engin" "${WORK_DIR}/csvs/custom"
echo "WORK_DIR=${WORK_DIR}"
'

# 在宿主机创建工作路径（如果需要）
ssh <NODE_IP> "mkdir -p /public/home/<user>/skilltest/vllm-perf-validation-single/work_dirs/<MODEL>-<TEST_MODE>-<DATE>-<CONTAINER_NAME>/{logs,csvs/{full,pchit,engin,custom}}"
```

### 环境变量传递

| 变量 | 说明 | 示例 |
|------|------|------|
| `WORK_DIR` | 统一工作路径根目录 | `/mnt/skilltest/vllm-perf-validation-single/work_dirs/...` |
| `TEST_MODE` | 测试模式（用于子目录） | `full`、`pchit`、`engin`、`custom` |
| `LOG_DIR` | 日志目录 | `${WORK_DIR}/logs` |
| `IMAGE_NAME` | 镜像名称（用于路径命名） | `25401bd053af` |
| `CONTAINER_NAME` | 容器名称（用于路径命名） | `<container_prefix>-0428-glm47int8-2540` |

---

## 4. 环境差异诊断

当自动化启动出现缺库、`ImportError` 时，用于判断是交互式还是非交互式 shell 环境问题。

### 诊断命令

以下命令只用于人工诊断，不应出现在正式自动化执行流程中。正式流程应由
`run_single_task.sh` 和 `run_bench.sh` 内置环境检查完成。

```bash
# 比较两种 shell 环境的 LD_LIBRARY_PATH 和 torch 导入
ssh <NODE_IP> "docker exec <CONTAINER> bash -lc '
echo === non-interactive_lc ===
echo LD_LIBRARY_PATH=\$LD_LIBRARY_PATH
python3 - <<PY 2>&1 || true
import torch
print("torch ok")
PY
'"

ssh <NODE_IP> "docker exec <CONTAINER> bash -ic '
echo === interactive_ic ===
echo LD_LIBRARY_PATH=\$LD_LIBRARY_PATH
python3 - <<PY 2>&1 || true
import torch
print("torch ok")
PY
'"
```

如果 `bash -ic` 可以导入 torch 而 `bash -lc` 失败，后续服务启动必须使用 `bash -ic`。

---

## 5. 健康检查模板

### 基础健康检查

```bash
ssh <NODE_IP> "docker exec <CONTAINER_NAME> bash -ic '
curl -sS -m 20 -X POST \"http://127.0.0.1:<PORT>/v1/chat/completions\" \
  -H \"Content-Type: application/json\" \
  -d \"{\\\"model\\\":\\\"<SERVED_MODEL_ID>\\\",\\\"temperature\\\":0,\\\"top_p\\\":1,\\\"max_tokens\\\":16,\\\"messages\\\":[{\\\"role\\\":\\\"user\\\",\\\"content\\\":\\\"你好\\\"}]}\"
'"
```

### 检查服务进程

```bash
ssh <NODE_IP> "docker exec <CONTAINER_NAME> bash -ic 'ps aux | grep -E \"vllm|ray|python|APIServer\" | grep -v grep'"
```

---

## 6. vllm bench serve

以下命令只用于排障和理解参数。正式测试不要直接执行这些命令，应通过
`scripts/ops/run_bench.sh` 间接调用，确保 `served_model_id`、`state.json`、CSV 和失败原因被记录。

### 基础基准测试

```bash
vllm bench serve \
  --model <SERVED_MODEL_ID> \
  --port <PORT> \
  --random-input-len 16384 \
  --random-output-len 10 \
  --num-prompts 8 \
  --dataset-name random \
  --ignore-eos \
  --profile
```

### 带 percentile 的基准测试

```bash
vllm bench serve \
  --model <SERVED_MODEL_ID> \
  --port <PORT> \
  --random-input-len <INPUT_LEN> \
  --random-output-len <OUTPUT_LEN> \
  --num-prompts <NUM_PROMPTS> \
  --max-concurrency <CONCURRENCY> \
  --dataset-name random \
  --metric-percentiles 95,99 \
  --ignore-eos \
  --trust-remote-code
```

### Prefix Cache 命中率测试

```bash
# 命中率 = prefix_len / total_input_len
# 例如：input_len=65536, prefix_len=32768 → 50% 命中率

vllm bench serve \
  --model <SERVED_MODEL_ID> \
  --dataset-name random \
  --random-input-len <RANDOM_INPUT_LEN> \
  --random-output-len <OUTPUT_LEN> \
  --random-prefix-len <PREFIX_LEN> \
  --num-prompts <NUM_PROMPTS> \
  --max-concurrency <CONCURRENCY> \
  --port <PORT> \
  --metric-percentiles 95,99 \
  --ignore-eos \
  --trust-remote-code
```

---

## 7. API 测试 (curl)

### 基础 chat completions

```bash
curl -sS -X POST "http://<HOST>:<PORT>/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<SERVED_MODEL_ID>",
    "temperature": 0,
    "top_p": 1,
    "max_tokens": 500,
    "messages": [{"role": "user", "content": "你好，介绍一下你自己"}]
  }'
```

### 长文本生成

```bash
curl -sS -X POST "http://127.0.0.1:9348/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "/model/GLM-4.7-W8A8",
    "temperature": 0,
    "top_p": 1,
    "max_tokens": 2000,
    "messages": [{"role": "user", "content": "写一篇1000字的短篇小说"}]
  }'
```

---

## 8. 常用环境变量

### vLLM 性能调优

| 环境变量 | 说明 | 示例 |
|----------|------|------|
| `HIP_VISIBLE_DEVICES` | GPU 设备 | `0,1,2,3,4,5,6,7` |
| `VLLM_NUMA_BIND` | NUMA 绑定 | `1` |
| `VLLM_TORCH_PROFILER_DIR` | 性能分析输出目录 | `./prof` |
| `VLLM_RPC_TIMEOUT` | RPC 超时 | `1800000` |
| `VLLM_HOST_IP` | 主机 IP | `$(hostname -I | awk '{print $1}')` |

### NCCL 调优

| 环境变量 | 说明 |
|----------|------|
| `NCCL_MIN_NCHANNELS` | 最小通道数 |
| `NCCL_MAX_NCHANNELS` | 最大通道数 |
| `NCCL_P2P_NVL_CHUNKSIZE` | P2P chunk 大小 |

---

## 9. 工具安装

### evalscope 安装

```bash
pip install evalscope -i http://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com
pip install 'evalscope[all]' -i http://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com
pip install 'evalscope[perf]' -i http://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com
```

### OpenCompass 安装

```bash
python setup.py bdist_wheel
cd dist
pip install opencompass*.whl
```

---

## 10. DCU 运维指令

### 查看 DCU 显卡信息

```bash
# 查看所有 DCU 显卡基本信息
ssh <NODE_IP> "/opt/hyhal/bin/hy-smi"

# 查看 DCU 利用率（实时）
ssh <NODE_IP> "/opt/hyhal/bin/hy-smi -c"
```

### DCU 进程监控

```bash
# 查看 DCU 进程
ssh <NODE_IP> "ps aux | grep -E 'rocminfo|clinfo' | grep -v grep"

# 查看 DCU 内存使用
ssh <NODE_IP> "/opt/hyhal/bin/hy-smi -q"
```

### GPU 绑定检查

```bash
# 检查 HIP_VISIBLE_DEVICES
ssh <NODE_IP> "echo \$HIP_VISIBLE_DEVICES"

# 检查 GPU 进程
ssh <NODE_IP> "ps aux | grep -E 'python|vllm|ray' | grep -v grep"

# 查看 /dev/dri 设备
ssh <NODE_IP> "ls -la /dev/dri/"
```

### 节点空闲检查

```bash
# 检查节点是否空闲（CPU 和内存）
ssh <NODE_IP> "uptime && free -h"

# 检查 Docker 是否可用
ssh <NODE_IP> "docker version"

# 检查 GPU 可见性
ssh <NODE_IP> "ls -la /dev/kfd && ls -la /dev/dri/"
```

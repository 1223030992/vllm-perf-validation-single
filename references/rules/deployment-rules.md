# 部署规则

本文件定义镜像拉取、节点检查、服务启动和 readiness 检查的标准流程。

---

## 0. 命名规范

### 容器命名格式

```
<container_prefix>-<MMDD>-<MODEL_SHORT>-<IMAGE_PREFIX>

示例：
<container_prefix>-0428-glm47int8-2540
```

MODEL_SHORT 规则：
- GLM-4.7-W8A8 / GLM-4.7-Channel-INT8 → glm47int8
- GLM-5.1-Channel-INT8 → glm51int8
- GLM-4.7-W8A16 / GLM-4.7-Channel-FP8 → glm47fp8
- GLM-5.1-Channel-FP8 → glm51fp8
- GLM-4.7（未标精度，默认 bf16）→ glm47
- GLM-5.1（未标精度，默认 bf16）→ glm51

### 工作路径命名格式

```
<MODEL>-<TEST_MODE>-<DATE>-<CONTAINER_NAME>/

示例：
/public/home/<user>/skilltest/vllm-perf-validation-single/work_dirs/GLM-4.7-W8A8-serial-full-20260515-<container_prefix>-0428-glm47int8-2540/
```

---

## 1. 部署前检查

对于每个模型，在启动前必须检查：

1. 节点是否可连接
2. Docker 是否可用
3. GPU 是否可见
4. GPU 数量是否满足 TP
5. 目标端口是否空闲
6. 模型路径是否存在
7. 启动脚本是否存在
8. 日志目录是否可写
9. 容器名是否冲突
10. image 是否明确

任意一项失败，都不得进入启动阶段。

---

## 2. 模型默认资源要求

| 模型 | 默认 TP | 最低 GPU 数量 |
|------|---------|---------------|
| GLM-4.7-W8A8 | 8 | 8 |
| GLM-5.1-Channel-INT8 | 8 | 8 |
| Qwen3.5-27B | 2 | 2 |

- 如果用户给出的 TP 小于默认值，必须提示风险
- 如果 GPU 数量小于 TP，必须阻止启动

---

## 3. 节点检查建议项

建议检查并记录以下信息（按推荐顺序）：

```bash
# 1. hostname
ssh <NODE_IP> "hostname"

# 2. DCU/GPU 型号和数量（优先 hy-smi，fallback rocm-smi/nvidia-smi）
ssh <NODE_IP> "/opt/hyhal/bin/hy-smi --showid 2>/dev/null || rocm-smi --showid 2>/dev/null || nvidia-smi -L 2>/dev/null || echo 'NO GPU TOOL'"

# 3. DCU/GPU 数量
ssh <NODE_IP> "/opt/hyhal/bin/hy-smi -i 2>/dev/null | grep -c 'DCU' || rocm-smi -i 2>/dev/null | grep -c 'GPU' || ls /sys/class/drm/ 2>/dev/null | grep -c 'card[0-9]'"

# 4. GPU 显存
ssh <NODE_IP> "/opt/hyhal/bin/hy-smi --showmeminfo vram 2>/dev/null || rocm-smi --showmeminfo vram 2>/dev/null || echo 'VRAM CHECK SKIPPED'"

# 5. Docker 版本和权限
ssh <NODE_IP> "docker --version && docker ps --format '{{.Names}}' | head -5"

# 6. 端口占用
ssh <NODE_IP> "ss -tlnp | grep -E ':(9348|9350)' || echo 'Ports 9348/9350 free'"

# 7. 模型路径（启动容器前检查宿主机路径）
ssh <NODE_IP> "test -d /public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8 && echo '模型目录存在' || echo '模型目录不存在'"

# 8. 日志目录
ssh <NODE_IP> "test -d /public/home/<user> && touch /public/home/<user>/.test_write 2>&1 && rm /public/home/<user>/.test_write && echo 'WRITABLE' || echo 'NOT WRITABLE'"

# 9. 磁盘空间
ssh <NODE_IP> "df -h /public/home/<user> | tail -1"

# 10. 容器名冲突
ssh <NODE_IP> "docker ps -a --format '{{.Names}}' | grep '<container_prefix>' || echo '无容器名冲突'"

# 11. 镜像是否存在（按 IMAGE ID 精确匹配，使用 docker image inspect）
ssh <NODE_IP> "docker image inspect 25401bd053af --format '{{.RepoTags}}' 2>/dev/null || echo '镜像不存在'"
```

---

## 4. image 处理规则

镜像处理必须遵循：

- **只使用用户明确指定或 task.yaml 指定的 image**
- **如果 image 缺失，必须询问用户，不得从 docker images 中自行挑选**
- 不擅自替换 tag
- 不自动切换 registry
- 不自动把固定 tag 改为 latest
- **失败后不得自动换镜像，只能报告错误并请求用户确认**
- 拉取失败后应直接报错并停止该模型任务

推荐记录：image name、tag、digest（如果能拿到）、pull start/end time、pull result。

---

## 5. 启动脚本规则

用户提供的启动脚本是服务启动的权威来源。

**Skill 可以：**

- 检查脚本存在、可执行
- 将环境变量注入脚本运行上下文
- 执行脚本
- 记录 stdout / stderr
- 记录容器名、端口、endpoint
- 记录当前启动日志路径

**Skill 默认不可以：**

- 改写脚本内容
- 自动改参数、镜像、模型路径、TP、端口、volume mount
- 自动关闭或开启优化参数

如果服务脚本在交互式容器 shell 中可以启动，而自动化启动失败，应优先修正自动化启动方式，而不是修改服务脚本。

---

## 6. 推荐环境变量

如果需要向启动脚本注入上下文，建议统一使用：

| 变量 | 说明 |
|------|------|
| RUN_ID | 运行 ID |
| MODEL_NAME | 模型名称 |
| MODEL_PATH | 容器内模型路径，用于服务启动脚本 |
| SERVED_MODEL_ID | `/v1/models` 返回的模型 ID，用于健康检查和 bench |
| BENCH_MODEL_ID | `vllm bench serve --model` 使用的模型 ID，默认等于 SERVED_MODEL_ID |
| DOCKER_IMAGE | 镜像名称 |
| TP_SIZE | Tensor Parallel 大小 |
| HOST_PORT | 宿主机端口 |
| CONTAINER_PORT | 容器内端口 |
| CONTAINER_NAME | 容器名称 |
| LOG_DIR | 日志目录 |
| VISIBLE_DEVICES | 可见设备 |
| GPU_RANGE | GPU 范围，如 "0,1,2,3" |
| VLLM_EXTRA_ARGS | vLLM 额外参数 |

这些变量用于标准化脚本调用，不代表脚本必须全部使用。

不得在未确认的情况下覆盖启动脚本中已有的核心优化变量。

---

## 7. 服务启动方式

### 必须复现交互式容器环境

DCU vLLM 服务启动必须复现用户手动执行：

```bash
docker exec -it <CONTAINER_NAME> bash
bash /mnt/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/<SERVER_SCRIPT>
```

的交互式 shell 环境。

**必须使用：**

```bash
docker exec -w /mnt/.claude/skills/vllm-perf-validation-single <CONTAINER_NAME> bash -ic '<COMMAND>'
```

**禁止使用：**

- `docker exec <CONTAINER> bash <SCRIPT>`
- `docker exec -d <CONTAINER> bash <SCRIPT>`
- `docker exec <CONTAINER> bash -lc 'bash <SCRIPT>'`
- `ssh <NODE> "docker exec <CONTAINER> bash <SCRIPT> &"`

**原因：**

- `docker exec -d` 返回成功不代表服务成功启动
- `bash -lc` 可能不会加载交互式 shell 中的 DTK/HYHAL 环境
- 裸启动不捕获日志，脚本退出后无法定位原因
- 外层 SSH 后台化可能导致进程托管不稳定
- `$!` 可能不是容器内 vLLM 服务进程
- 非交互 shell 可能缺失 `/opt/dtk/*`、`/opt/hyhal/*` 等动态库路径

### 环境差异诊断

当自动化启动出现缺库、`ImportError` 或 `cannot open shared object file`，且用户手动交互 shell 能启动时，必须先比较两种 shell 环境：

```bash
# 比较 LD_LIBRARY_PATH 和 torch 导入
ssh <NODE_IP> "docker exec <CONTAINER> bash -lc '
echo LD_LIBRARY_PATH=\$LD_LIBRARY_PATH
python3 - <<PY 2>&1 || true
import torch
PY
'"

ssh <NODE_IP> "docker exec <CONTAINER> bash -ic '
echo LD_LIBRARY_PATH=\$LD_LIBRARY_PATH
python3 - <<PY 2>&1 || true
import torch
PY
'"
```

如果 `bash -ic` 可以导入 torch 而 `bash -lc` 失败，后续服务启动必须使用 `bash -ic`。

不得逐个猜测并追加单个 `LD_LIBRARY_PATH`，除非用户明确要求进行底层环境调试。

---

## 8. 日志路径规则

服务启动日志必须使用绝对路径：

```
/mnt/skilltest/vllm-perf-validation-single/tmp/<MODEL_NAME>-<MMDD>-vllm-server.log
```

PID 文件必须使用绝对路径：

```
/mnt/skilltest/vllm-perf-validation-single/tmp/<MODEL_NAME>-<MMDD>-vllm-server.pid
```

**启动服务前必须清理旧日志和旧 PID：**

```bash
rm -f "$LOG" "$PID"
```

避免被上一次失败日志误导。

**禁止在未设置工作目录时使用相对日志路径**，除非 docker exec 已明确带有 `-w /mnt/skilltest/vllm-perf-validation-single`。

---

## 9. 服务启动成功判据

不得以以下信号判断服务成功：

- `docker exec` 返回 0
- `nohup` 返回 PID
- 命令没有报错
- 容器仍在运行

**服务启动成功必须满足以下至少一项：**

1. 容器内存在 `vllm` / `ray` / `python` / `APIServer` 进程
2. 当前日志出现 vLLM banner、`APIServer pid` 或模型加载日志
3. 当前日志出现：
   - `Starting vLLM API server`
   - `Application startup complete`
   - `/v1/chat/completions`
4. 健康检查成功返回

服务就绪后必须调用 `GET /v1/models`，记录第一个 `id` 为
`served_model_id`。后续健康检查和 bench 必须使用这个 ID。

**服务启动失败判据：**

- 当前日志出现 `Traceback`
- 当前日志出现 `ImportError`
- 当前日志出现 `RuntimeError`
- 当前日志出现 `cannot open shared object file`
- 服务进程退出
- 端口在超时时间内始终无法访问
- 健康检查持续失败直到超时

---

## 10. readiness 检查

### 等待中信号（不是失败）

以下日志信息是模型加载/编译过程中的常见状态，**不是失败信号**，必须继续等待直到 timeout：

- `Loading safetensors checkpoint shards` - 正在加载模型权重
- `torch.compile takes ...` - 正在进行 Torch 编译
- `No available shared memory broadcast block found` - 正在等待共享内存初始化
- `Initializing moe_cache_singleton` - 正在初始化 MoE 缓存
- `hipModuleLoad ... Success` - 正在加载 HIP 模块
- `engine core initialization` - 正在初始化引擎核心

**判断失败的依据：**
- 日志出现 `Traceback` 或 `Exception`
- 服务进程退出
- 端口在超时时间内始终无法访问
- 健康检查持续失败直到超时

### 标准等待策略

服务启动后，不要立即判失败。

**标准等待策略：**

1. 启动后等待 10 秒
2. 检查进程和当前日志
3. 如果正在加载模型，继续等待
4. 每 60 秒检查一次
5. 直到健康检查通过或超过 `service.health_check.timeout_seconds`

**健康检查示例：**

```bash
served_model_id=$(curl -sS -m 20 "http://127.0.0.1:<PORT>/v1/models" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
curl -sS -m 20 -X POST "http://127.0.0.1:<PORT>/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${served_model_id}\",\"temperature\":0,\"top_p\":1,\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}]}"
```

健康检查通过后才能执行性能测试。

---

## 11. readiness 超时处理

如果在约定时间内未 ready：

1. 收集当前服务日志
2. 记录 endpoint
3. 记录超时时间
4. 记录容器进程
5. 标记 `SERVICE_TIMEOUT` 或 `READINESS_CHECK_FAILED`
6. 停止进入性能测试
7. 保留现场，不自动删除容器

**注意：**

- 大模型启动时，不允许启动后 30 秒内直接判失败
- 标准检查节奏：启动后等待 10 秒 → 检查进程和日志 → 如仍在加载继续等待 → 每 60 秒检查一次 → 直到健康检查通过或超时

---

## 12. 禁止事项汇总

- 禁止将 `docker exec` 返回成功当作服务成功
- 禁止在未设置工作目录时使用相对日志路径
- 禁止使用 `docker exec -d` 启动服务
- 禁止在交互式 shell 能启动的情况下直接修改服务脚本
- 禁止逐个猜测 `LD_LIBRARY_PATH` 除非用户明确要求底层调试
- **禁止自动选择镜像**：如果用户未指定镜像，必须询问，不得从 docker images 中自行挑选
- **禁止自动换镜像**：失败后不得自动换镜像，只能报告错误并请求用户确认

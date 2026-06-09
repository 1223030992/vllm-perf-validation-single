# vLLM DCU 性能验证 Skill 使用技术文档

本文档面向实际使用者和版本维护者，说明如何用 `vllm-perf-validation-single`
在单个 DCU/GPU 节点上安全执行 vLLM 推理性能测试，并如何整理反馈用于后续迭代。

## 1. 使用目标

本 Skill 适合以下场景：

- 在真实 DCU 节点上验证 vLLM 服务能否启动、就绪和完成 benchmark。
- 对单模型执行冒烟、full、Prefix Cache 命中率、Prefill 或 custom 测试。
- 对多个模型执行 serial 测试，确保上一个模型释放端口和 GPU 后再启动下一个模型。
- 新增模型启动脚本、profile 和 example task，并纳入统一命名和报告体系。
- 生成可追踪的 `state.json`、CSV、JSON 报告和 Markdown 报告，便于问题复盘。

## 2. 核心目录

```text
SKILL.md                         # 入口规则和导航
task.yaml                        # 默认 single 冒烟任务
agents/openai.yaml               # Codex UI 展示信息和触发策略

references/
  conventions.md                 # 命名、端口、MODEL_SHORT 映射
  usage-guide.md                 # 本使用文档
  profiles/                      # 模型默认配置
  examples/                      # 可参考的任务配置
  schemas/                       # task/report 结构说明
  rules/                         # 部署、评测、日志分类规则

scripts/
  ops/                           # 推荐直接调用的状态机脚本
  server-scripts/                # vLLM 服务启动脚本
  client-scripts/                # vLLM bench serve 测试脚本
  add-model.sh                   # 旧版新增模型生成器；新流程优先使用 scripts/ops/register_model.sh
```

运行产物不要写回 Skill 安装目录，应写入：

```text
/mnt/skilltest/vllm-perf-validation-single/work_dirs/<run_id>/
```

## 3. 关键概念

### 3.1 模型路径和模型身份

必须区分四个字段：

| 字段 | 用途 |
|---|---|
| `host_model_path` | preflight 阶段在宿主机上检查目录是否存在 |
| `container_model_path` | 服务启动脚本加载模型时使用的容器内路径 |
| `served_model_id` | 服务启动后通过 `/v1/models` 发现的模型 id |
| `bench_model_id` | 传给 `vllm bench serve --model` 的模型 id，默认等于 `served_model_id` |

示例：GLM-4.7-W8A8 在当前环境中：

```yaml
host_model_path: /public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8
container_model_path: /model/GLM-4.7-W8A8
served_model_id: /model/GLM-4.7-W8A8
bench_model_id: /model/GLM-4.7-W8A8
```

不要用口头模型名直接做 benchmark。必须先等服务就绪，再以 `/v1/models`
发现的 `served_model_id` 为准。

### 3.2 运行状态文件

ops 流程会围绕同一个 `state.json` 更新状态：

```text
WORK_DIR=/mnt/skilltest/vllm-perf-validation-single/work_dirs/<run_id>
STATE=$WORK_DIR/state.json
```

`state.json` 记录节点、镜像、容器、模型路径、`served_model_id`、日志、CSV、
启动耗时、就绪耗时、测试状态和失败原因。生成报告时必须读取它。

### 3.3 高风险操作确认

以下操作必须先确认：

- 首次 SSH 到新节点。
- 创建容器。
- 占用 GPU/DCU。
- 占用端口。
- 拉取镜像。
- 停止容器。
- 删除容器。

自动流程永远不执行 `docker rm`。只有用户明确点名容器并要求删除时，才可以考虑删除。

## 4. 标准执行流程

### 4.1 推荐入口：单模型自动化执行

单模型 `custom` 冒烟或回归任务必须使用绝对路径形式的 `run_single_task.sh`。它会串联执行
`preflight -> create -> start -> wait -> bench -> render report -> stop -> render final report -> show state`，
避免 Claude 把流程拆成多条 Bash 变量块、手写 SSH/Docker 命令或反复触发权限询问。

正式执行时必须使用下面这种命令形态，避免权限规则不匹配：

```text
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh ...
```

不要使用 `cd` 进入 Skill 目录后再调用相对路径脚本；不要在正式流程中先单独执行
`preflight_node.sh`；不要使用 `SKILL_ROOT=...` 变量块再拼接脚本路径；不要使用
`DRY_RUN=1 bash ...` 或 `DRY_RUN=0 bash ...` 环境变量前缀。这些命令形态无法匹配推荐的 allow 规则。

GLM-4.7-W8A8 最小冒烟示例：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh \
  --node 10.16.1.9 \
  --image "10.16.1.254:5000/jenkins/model_test_env/vllm:daily-20260428-1927" \
  --model-name GLM-4.7-W8A8 \
  --model-short glm47int8 \
  --host-model-path /public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8 \
  --container-model-path /model/GLM-4.7-W8A8 \
  --server-script scripts/server-scripts/run_glm47int8-server.sh \
  --port 9348 \
  --tp 8 \
  --gpu-range "0,1,2,3,4,5,6,7" \
  --test-mode custom \
  --input-lens "512" \
  --output-len 32 \
  --concurrencies "1" \
  --num-prompts-mult 1 \
  --percentiles "50,95,99" \
  --date 0520 \
  --image-prefix 2540 \
  --assume-yes
```

GLM-5.1-Channel-INT8 最小冒烟示例应显式使用更长等待超时：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh \
  --node 10.16.1.9 \
  --image "10.16.1.254:5000/jenkins/model_test_env/vllm:daily-20260428-1927" \
  --model-name GLM-5.1-Channel-INT8 \
  --model-short glm51int8 \
  --host-model-path /public4/share/GLM-5.1-Channel-INT8 \
  --container-model-path /model1/GLM-5.1-Channel-INT8 \
  --server-script scripts/server-scripts/run_glm5.1-w8a8-server.sh \
  --port 9350 \
  --tp 8 \
  --gpu-range "0,1,2,3,4,5,6,7" \
  --test-mode custom \
  --input-lens "512" \
  --output-len 32 \
  --concurrencies "1" \
  --num-prompts-mult 1 \
  --percentiles "50,95,99" \
  --timeout 2400 \
  --assume-yes
```

调试参数可先加 `--dry-run`，只检查主流程参数，不执行真实 SSH、Docker 或 GPU 操作。
dry-run 不连接目标节点解析镜像 ID；需要验证最终容器名时请同时传入 `--image-prefix 2540`。

### 4.2 分步入口：排障或扩展时使用

需要排障时才使用分步入口，且必须由用户明确要求“诊断模式”。正式单模型 custom 流程不要拆分执行。
推荐顺序如下：

```text
preflight_node.sh
create_container.sh
start_vllm_service.sh
wait_vllm_ready.sh
run_bench.sh
render_report.py
stop_service.sh
render_report.py
```

执行纪律：

- 不要把 `scripts/client-scripts/*.sh` 当作主流程入口直接调用；必须通过 `scripts/ops/run_bench.sh` 执行。
- 不要手写 readiness 轮询循环。`wait_vllm_ready.sh` 失败时应记录错误并反馈，不要临时拼接新的 SSH/Docker 脚本继续跑。
- 不要手写 `docker stop`。停止服务必须使用 `scripts/ops/stop_service.sh`，这样才能验证端口释放并更新 `state.json`。
- `run_single_task.sh` 如果在 stop/report 阶段失败，应使用输出中的
  `scripts/ops/recover_single_task.sh --state ...` 恢复入口，不要临时拼接 `ssh docker stop`。
- benchmark 完成后先生成报告，再停止容器；stop 完成后重新生成最终报告。
- 容器内涉及 `vllm` 或 `torch` 的命令必须通过 `bash -ic` 执行。普通 `bash -c` 在 DCU 镜像中可能缺少 DTK/HIP 环境。
- 停止容器后读取产物时，应使用宿主机路径 `/public/home/<user>/skilltest/...`，不要直接读容器路径 `/mnt/skilltest/...`。

### 4.3 Claude Code 权限建议

为了减少重复询问，建议只 allow 稳定入口脚本，不要继续 allow 历史长命令或分步 ops 脚本。示例：

```json
{
  "permissions": {
    "allow": [
      "Read(/public/home/<user>/.claude/skills/vllm-perf-validation-single/**)",
      "Read(/public/home/<user>/skilltest/vllm-perf-validation-single/**)",
      "Bash(bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh *)",
      "Bash(bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh *)",
      "Bash(bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/standardize_server_script.sh *)",
      "Bash(bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/show_state.sh *)",
      "Bash(bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/recover_single_task.sh *)",
      "Bash(bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/resume_single_task.sh *)"
    ],
    "deny": [
      "Bash(*docker rm*)",
      "Bash(*docker system prune*)",
      "Bash(*docker image prune*)",
      "Bash(*rm -rf*)"
    ]
  }
}
```

正式执行时，prompt 中应要求 Claude 只调用绝对路径 `run_single_task.sh`，不要单独 preflight，
不要生成多行 Bash 变量块，不要使用 `DRY_RUN=... bash ...`，不要手写 SSH/Docker/vLLM 命令。

### 4.4 环境检查

正式流程不要单独执行环境检查，`run_single_task.sh` 已内置 preflight。诊断模式需要单独检查时，
使用参数形式 `--dry-run`，不要使用 `DRY_RUN=1` 前缀：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/preflight_node.sh \
  --node 10.16.1.9 \
  --image 10.16.1.254:5000/jenkins/model_test_env/vllm:daily-20260428-1927 \
  --ports "9348" \
  --host-model-paths "/public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8" \
  --container-names "<container_prefix>-0520-glm47int8-2540" \
  --dry-run
```

### 4.5 创建容器

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/create_container.sh \
  --node 10.16.1.9 \
  --image 10.16.1.254:5000/jenkins/model_test_env/vllm:daily-20260428-1927 \
  --model-short glm47int8 \
  --date 0520 \
  --image-prefix 2540 \
  --dry-run
```

真实创建前必须确认。执行成功后记录输出的：

```text
CONTAINER_NAME=<container_prefix>-0520-glm47int8-2540
```

### 4.6 启动服务

```bash
bash scripts/ops/start_vllm_service.sh \
  --node 10.16.1.9 \
  --container <container_prefix>-0520-glm47int8-2540 \
  --model-name GLM-4.7-W8A8 \
  --model-short glm47int8 \
  --host-model-path /public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8 \
  --container-model-path /model/GLM-4.7-W8A8 \
  --server-script scripts/server-scripts/run_glm47int8-server.sh \
  --test-mode custom \
  --port 9348 \
  --tp 8 \
  --gpu-range "0,1,2,3,4,5,6,7" \
  --image 25401bd053af
```

该脚本会输出：

```text
WORK_DIR=...
LOG=...
PID=...
STATE=...
```

后续步骤必须复用同一个 `WORK_DIR` 和 `STATE`。

### 4.7 等待服务就绪

```bash
bash scripts/ops/wait_vllm_ready.sh \
  --node 10.16.1.9 \
  --container <container_prefix>-0520-glm47int8-2540 \
  --port 9348 \
  --log "$LOG" \
  --model-path /model/GLM-4.7-W8A8 \
  --state "$STATE" \
  --timeout 1800 \
  --interval 60
```

成功时输出：

```text
SERVED_MODEL_ID=/model/GLM-4.7-W8A8
```

若日志出现 `torch.compile takes`、`No available shared memory broadcast block found`、
`Loading safetensors checkpoint shards`，通常表示仍在加载或编译，不要立即判失败。

### 4.8 运行性能测试

```bash
export INPUT_LENS="512"
export OUTPUT_LEN=32
export CONCURRENCIES="1"
export NUM_PROMPTS_MULT=1
export PERCENTILES="50,95,99"

bash scripts/ops/run_bench.sh \
  --node 10.16.1.9 \
  --container <container_prefix>-0520-glm47int8-2540 \
  --test-mode custom \
  --served-model-id "$SERVED_MODEL_ID" \
  --port 9348 \
  --tp 8 \
  --work-dir "$WORK_DIR" \
  --state "$STATE"
```

`run_bench.sh` 会强制把 `served_model_id` 传给 client 脚本，避免使用错误路径导致 404。

### 4.9 生成停止前报告

benchmark 完成后先生成一次报告，避免容器停止后才发现报告链路缺少容器内上下文。

```bash
python scripts/ops/render_report.py \
  --run-id glm47-smoke-0520 \
  --state "$STATE" \
  --csv "$WORK_DIR/csvs/custom/all.csv" \
  --report-dir /public/home/<user>/skilltest/vllm-perf-validation-single/reports
```

如果 `state.json` 中已经记录 `paths.csv_file`，可以不传 `--csv`。

### 4.10 停止服务

```bash
bash scripts/ops/stop_service.sh \
  --node 10.16.1.9 \
  --container <container_prefix>-0520-glm47int8-2540 \
  --port 9348 \
  --state "$STATE"
```

该脚本只执行 `docker stop` 并验证端口释放，不会执行 `docker rm`。

### 4.11 生成最终报告

stop 成功或失败后，再生成一次最终报告，让报告包含最终状态和端口释放结果。

```bash
python scripts/ops/render_report.py \
  --run-id glm47-smoke-0520 \
  --state "$STATE" \
  --csv "$WORK_DIR/csvs/custom/all.csv" \
  --report-dir /public/home/<user>/skilltest/vllm-perf-validation-single/reports
```

## 5. 使用实例

### 实例 1：GLM-4.7-W8A8 单模型冒烟测试

目标：

- 节点：`10.16.1.9`
- 镜像：`25401bd053af`
- 模型：`GLM-4.7-W8A8`
- 测试模式：`custom`
- 输入：512
- 输出：32
- 并发：1
- 请求数：1

关键参数应直接写入 `run_single_task.sh` 的命令行参数，不要先声明 Bash 变量：

| 字段 | 值 |
|---|---|
| `--node` | `10.16.1.9` |
| `--image` | `10.16.1.254:5000/jenkins/model_test_env/vllm:daily-20260428-1927` |
| `--model-name` | `GLM-4.7-W8A8` |
| `--model-short` | `glm47int8` |
| `--host-model-path` | `/public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8` |
| `--container-model-path` | `/model/GLM-4.7-W8A8` |
| `--port` | `9348` |
| `--tp` | `8` |
| `--gpu-range` | `0,1,2,3,4,5,6,7` |
| `--input-lens` / `--output-len` / `--concurrencies` | `512` / `32` / `1` |

验收标准：

- `/v1/models` 返回 `served_model_id`。
- `all.csv` 至少有 1 行结果。
- `status=PASS`。
- 报告中 `failed=0`。

可直接发送给 Claude 的指令模板：

```text
/vllm-perf-validation-single 使用 vllm-perf-validation-single skill，在 10.16.1.9 节点测试 GLM-4.7-W8A8 模型。
镜像：10.16.1.254:5000/jenkins/model_test_env/vllm:daily-20260428-1927
模式：single
测试模式：custom
host_model_path: /public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8
container_model_path: /model/GLM-4.7-W8A8
service_script: scripts/server-scripts/run_glm47int8-server.sh
端口：9348
TP：8
GPU_RANGE: 0,1,2,3,4,5,6,7
测试组合：input_lens=512，output_len=32，concurrencies=1，num_prompts_mult=1，percentiles=50,95,99。

请严格只调用绝对路径主入口：
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh ...

不要单独执行 preflight_node.sh，不要生成多行 Bash 变量块，不要调用 python3 -c，不要手写 SSH/Docker/vLLM 命令。
主入口会自动完成 preflight、创建容器、启动、等待 /v1/models、benchmark、停止容器和报告生成。

如果任一 ops 脚本失败，请停止流程并汇报脚本名、参数和错误输出，不要自行拼接新的 SSH/Docker 命令绕过。
创建容器、占用 GPU/端口、停止容器前分别只向我确认一次。禁止执行 docker rm。
```

### 实例 2：GLM-4.7 与 GLM-5.1 串行 custom 测试

目标：

- 先跑 GLM-4.7-W8A8，端口 9348。
- 停止并验证 9348 释放后，再跑 GLM-5.1-Channel-INT8，端口 9350。
- 输入：512、1024、2048。
- 输出：256。
- 并发：1、2、4、8。
- 请求数：`2 * concurrency`。

GLM-4.7 参数：

```bash
MODEL_NAME=GLM-4.7-W8A8
MODEL_SHORT=glm47int8
HOST_MODEL_PATH=/public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8
CONTAINER_MODEL_PATH=/model/GLM-4.7-W8A8
PORT=9348
SERVER_SCRIPT=scripts/server-scripts/run_glm47int8-server.sh
```

GLM-5.1 参数：

```bash
MODEL_NAME=GLM-5.1-Channel-INT8
MODEL_SHORT=glm51int8
HOST_MODEL_PATH=/public4/share/GLM-5.1-Channel-INT8
CONTAINER_MODEL_PATH=/model1/GLM-5.1-Channel-INT8
PORT=9350
SERVER_SCRIPT=scripts/server-scripts/run_glm5.1-w8a8-server.sh
```

benchmark 环境变量：

```bash
export INPUT_LENS="512 1024 2048"
export OUTPUT_LEN=256
export CONCURRENCIES="1 2 4 8"
export NUM_PROMPTS_MULT=2
export PERCENTILES="50,95,99"
```

串行规则：

```text
GLM-4.7: start -> wait -> bench -> stop -> verify release
GLM-5.1: start -> wait -> bench -> stop -> verify release
```

不要在 GLM-4.7 端口释放前启动 GLM-5.1。

### 实例 3：Prefix Cache 命中率测试

目标：

- 模型：GLM-4.7-W8A8。
- 输入长度：65536。
- 输出长度：256。
- 命中率：50、75、90、99。
- 并发：1、2、4、8。

环境变量：

```bash
export INPUT_LEN=65536
export OUTPUT_LEN=256
export CACHE_HIT_RATES="50 75 90 99"
export BATCHES="1 2 4 8"
export CONCURRENCY_MULTIPLIER=4
```

执行：

```bash
bash scripts/ops/run_bench.sh \
  --node 10.16.1.9 \
  --container "$CONTAINER" \
  --test-mode pchit \
  --served-model-id "$SERVED_MODEL_ID" \
  --port 9348 \
  --tp 8 \
  --work-dir "$WORK_DIR" \
  --state "$STATE"
```

验收标准：

- `all.csv` 中应覆盖 4 个 `cache_hit_pct`。
- 不应默认只跑 99。

### 实例 4：只做 dry-run 检查命令

适用于第一次接入新节点或新模型时：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh \
  --node 10.16.1.9 \
  --image 10.16.1.254:5000/jenkins/model_test_env/vllm:daily-20260428-1927 \
  --model-name GLM-4.7-W8A8 \
  --model-short glm47int8 \
  --host-model-path /public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8 \
  --container-model-path /model/GLM-4.7-W8A8 \
  --server-script scripts/server-scripts/run_glm47int8-server.sh \
  --port 9348 \
  --tp 8 \
  --gpu-range "0,1,2,3,4,5,6,7" \
  --test-mode custom \
  --input-lens "512" \
  --output-len 32 \
  --concurrencies "1" \
  --num-prompts-mult 1 \
  --percentiles "50,95,99" \
  --date 0520 \
  --image-prefix 2540 \
  --dry-run
```

dry-run 只打印主流程和参数，不执行真实 SSH/Docker/GPU 变更。

### 实例 5：新增模型

新增模型时优先使用本地注册入口，不要手写 profile/example，不要手写容器名：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh \
  --model-name GLM-5-W8A8 \
  --host-model-path /public/opendas/DL_DATA/llm-models/vllm-w8a8-models/GLM-5-W8A8 \
  --server-script /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/run_glm5-w8a8-server.sh \
  --dry-run
```

`register_model.sh` 不连接 SSH、Docker 或 GPU。它只修改本地 skill 文件，且会：

- 推导 `MODEL_SHORT`，例如 `GLM-5-W8A8 -> glm5int8`
- 推导容器路径，例如 `/public/opendas/DL_DATA/llm-models/... -> /model/...`
- 推导端口：GLM 使用固定默认端口；非 GLM 未传 `--port` 时使用已注册端口最大值 + 1
- 生成 `references/profiles/<MODEL_SHORT>.yaml`
- 生成 `references/examples/<MODEL_SHORT>-test-task.yaml`
- 更新 `references/conventions.md`
- 输出可直接复制的绝对路径 `run_single_task.sh --dry-run` 命令

Qwen 和 DeepSeek 蒸馏版推荐显式传 `--port`；如果不传，注册器会根据已有 profile/conventions 端口自动分配下一个端口。显式传入的端口始终优先：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh \
  --model-name Qwen3.5-35B-W8A8 \
  --host-model-path /public/opendas/DL_DATA/llm-models/qwen/Qwen3.5-35B-W8A8 \
  --server-script /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/run_qwen35b35int8-server.sh \
  --port 9360 \
  --dry-run
```

DeepSeek 蒸馏版示例：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh \
  --model-name DeepSeek-R1-Distill-Qwen-32B-W8A8 \
  --host-model-path /public4/share/DeepSeek-R1-Distill-Qwen-32B-W8A8 \
  --server-script /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/run_dsr1distillqwenb32int8-server.sh \
  --port 9362 \
  --dry-run
```

确认 dry-run 输出无误后，去掉 `--dry-run` 正式注册。默认不会覆盖已有文件；确实需要覆盖时，必须显式传入 `--overwrite`。

## 6. 常见问题

### benchmark 全部 404

常见原因是 `vllm bench serve --model` 使用了错误模型名。

处理方式：

1. 调用 `/v1/models`。
2. 记录返回的第一个 `id`。
3. 将该 id 作为 `--served-model-id` 传给 `run_bench.sh`。

### benchmark 报缺少 libgalaxyhip.so.5 或 librocm_smi64.so.2

常见原因是绕过了 `run_bench.sh`，或者在容器内用普通 `bash -c` 执行了 `vllm`/`torch`。

处理方式：

1. 停止手写 benchmark 命令。
2. 使用 `scripts/ops/run_bench.sh` 重新执行。
3. 确认脚本输出中没有 `BENCH_ENV_FAILED`。
4. 如果仍失败，反馈 `state.json` 中的 `failure.reason` 和 `paths.bench_env_check_log`。

### 停止容器后找不到 state.json 或 CSV

容器路径 `/mnt/skilltest/...` 只在容器内有效。容器停止后，应使用宿主机路径：

```text
/public/home/<user>/skilltest/vllm-perf-validation-single/...
```

`start_vllm_service.sh`、`run_bench.sh` 和 `stop_service.sh` 会输出 `*_HOST` 路径，后续汇总和报告生成优先使用这些路径。

### preflight 显示模型目录不存在

检查的是宿主机路径 `host_model_path`。它可以不同于容器内 `container_model_path`。
以 GLM-4.7-W8A8 为例，宿主机路径应是：

```text
/public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8
```

### wait 阶段长时间输出 shared memory broadcast

日志中出现：

```text
No available shared memory broadcast block found
torch.compile takes
Loading safetensors checkpoint shards
```

通常表示加载或编译中，不是立即失败。应继续等到超时，或直到出现失败信号。

### stop 后端口仍被占用

不要继续启动下一个模型。先检查：

```bash
ssh 10.16.1.9 "ss -tlnp | grep ':9348 '"
```

确认端口释放后再进入下一个模型。

### 报告生成失败

优先检查：

- `state.json` 是否存在。
- `state.paths.csv_file` 是否存在且指向真实 CSV。
- 是否需要显式传入 `--csv`。

## 7. 反馈模板

后续反馈问题时，建议按以下格式提供：

```text
节点:
镜像:
模型:
测试模式:
输入/输出/并发/请求数:
执行到哪一步:
使用的命令:
期望结果:
实际结果:
state.json 路径:
all.csv 路径:
服务日志路径:
报告路径:
是否复现:
补充说明:
```

如果涉及服务启动或就绪问题，请附上日志中最后 100 行；如果涉及性能结果异常，请附上
`all.csv` 和报告 JSON。

## 8. GLM-5 / Qwen 注册补充

- GLM-5-W8A8 首次启动建议使用 `--timeout 3600`。主入口对 `glm5*` 已默认使用 3600 秒。
- 如果主入口在 `SERVICE_TIMEOUT` 后退出，但服务随后就绪，继续流程必须调用：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/resume_single_task.sh \
  --state /public/home/<user>/skilltest/vllm-perf-validation-single/work_dirs/<RUN_DIR>/state.json
```

- 不要手写 `curl /v1/models`、不要直接调用 `run_bench.sh`、不要手造 CSV。
- Qwen、DeepSeek 等非 GLM 模型注册时不再默认 TP8。必须显式传 `--tp`，或让注册器从脚本中的 `-tp 2` / `--tensor-parallel-size 2` / `export TP_SIZE=2` / `export TP=2` 推导。
- Qwen、DeepSeek 等非 GLM 模型推荐显式传 `--port`；未传时注册器按已注册端口最大值 + 1 自动分配。该分配只避免注册配置冲突，真实节点端口是否空闲仍由正式测试 preflight 检查。
- Qwen3.5-35B-W8A8 若脚本为 TP2，dry-run 预期输出 `TP=2`、`GPU_RANGE=0,1`。若脚本无法推导 TP 且未传 `--tp`，注册应失败。
- 正式注册未参数化脚本默认失败；确认要保留静态脚本时才传 `--allow-static-server-script`。

## 9. 版本迭代建议

使用过程中优先反馈以下信息：

- 哪个命令最容易填错参数。
- 哪个字段含义不清晰。
- 哪些错误日志被误判为失败或等待。
- 哪些报告字段缺失。
- Serial 模式是否严格做到 stop 和端口释放后再启动下一个模型。
- `register_model.sh` 生成的 profile/example 是否需要人工修改过多。

这些反馈会直接用于后续版本优化。
## 新模型标准化注册流程

新增模型统一走四步，不要手写 profile/example，也不要直接用未标准化 server script 做正式注册：

1. `standardize_server_script.sh --dry-run`
2. `standardize_server_script.sh`
3. `register_model.sh --dry-run` / `register_model.sh`
4. `run_single_task.sh --dry-run` / `run_single_task.sh`

标准化入口不连接 SSH、Docker 或 GPU，只处理本地 server script：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/standardize_server_script.sh \
  --model-name MiniMax-M2.5-W8A8 \
  --model-short minimaxm25int8 \
  --server-script scripts/server-scripts/run_minimax2.5-w8a8.sh \
  --container-model-path /model2/llm-models/MiniMax-M2.5-W8A8 \
  --port 9352 \
  --tp 8 \
  --gpu-range 0,1,2,3,4,5,6,7 \
  --dry-run
```

正式执行标准化后，再注册：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh \
  --model-name MiniMax-M2.5-W8A8 \
  --model-short minimaxm25int8 \
  --host-model-path /public4/opendas/DL_DATA/llm-models/MiniMax-M2.5-W8A8 \
  --container-model-path /model2/llm-models/MiniMax-M2.5-W8A8 \
  --server-script scripts/server-scripts/run_minimax2.5-w8a8.sh \
  --port 9352 \
  --tp 8 \
  --gpu-range 0,1,2,3,4,5,6,7 \
  --dry-run
```

如果注册器发现脚本未标准化，会输出 `NEXT_STEP_STANDARDIZE_CMD`。正式注册默认拒绝未标准化脚本，除非显式传 `--allow-static-server-script`。

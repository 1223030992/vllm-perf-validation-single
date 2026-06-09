# 任务配置 Schema

本文档定义 `task.yaml` 的推荐结构。字段名保持英文，便于脚本读取；说明文字使用中文。

## 顶层结构

```yaml
task:
  name: vllm_perf_validation
  run_id: auto
  owner: liuzhihuan
  description: "vLLM 性能验证任务"

mode: single | serial | parallel

paths:
  skill_host_root: /public/home/<user>/.claude/skills/vllm-perf-validation-single
  skill_container_root: /mnt/.claude/skills/vllm-perf-validation-single
  output_host_root: /public/home/<user>/skilltest/vllm-perf-validation-single
  output_container_root: /mnt/skilltest/vllm-perf-validation-single

image:
  name: <image_name>
  pull_policy: if_not_present

node:
  ip: <NODE_IP>
  gpu_count: 8
  dcu_type: DCU | BW1000 | BW1100

container:
  name_template: "<container_prefix>-<MMDD>-<MODEL_SHORT>-<IMAGE_PREFIX>"

ops:
  preflight_script: scripts/ops/preflight_node.sh
  create_container_script: scripts/ops/create_container.sh
  start_service_script: scripts/ops/start_vllm_service.sh
  wait_ready_script: scripts/ops/wait_vllm_ready.sh
  run_bench_script: scripts/ops/run_bench.sh
  stop_service_script: scripts/ops/stop_service.sh
  render_report_script: scripts/ops/render_report.py

models:
  - name: <model_display_name>
    model_short: <MODEL_SHORT>
    host_model_path: /public/.../<MODEL_DIR>
    container_model_path: /model/<MODEL_DIR>
    served_model_id: null
    bench_model_id: null
    tp: <tensor_parallel>
    port: <PORT>
    gpu_range: "0,1,2,3,4,5,6,7"
    service_script: scripts/server-scripts/run_<model>-server.sh

service:
  health_check:
    endpoint: /v1/chat/completions
    timeout_seconds: 1800

test:
  mode: full | pchit | engin | custom
  script: scripts/client-scripts/run_perf_test-<mode>.sh
  params: {}

output:
  work_dir: /public/home/<user>/skilltest/vllm-perf-validation-single/work_dirs
  report_dir: /public/home/<user>/skilltest/vllm-perf-validation-single/reports
  csv_dir: /public/home/<user>/skilltest/vllm-perf-validation-single/csvs
```

## 字段说明

### task

| 字段 | 类型 | 说明 |
|---|---|---|
| `name` | string | 任务名称 |
| `run_id` | string | 运行 ID，`auto` 表示自动生成 |
| `owner` | string | 负责人 |
| `description` | string | 任务描述 |

### mode

| 值 | 说明 |
|---|---|
| `single` | 单模型独占 8 卡测试 |
| `serial` | 多模型顺序测试，每次只运行一个模型 |
| `parallel` | 两个 4 卡模型同时测试，GPU 范围必须互不重叠 |

### paths

| 字段 | 说明 |
|---|---|
| `skill_host_root` | Skill 在宿主机上的安装目录 |
| `skill_container_root` | Skill 在容器内的挂载目录 |
| `output_host_root` | 运行产物在宿主机上的根目录 |
| `output_container_root` | 运行产物在容器内的根目录 |

### model identity

| 字段 | 说明 |
|---|---|
| `host_model_path` | preflight 阶段在宿主机上检查的模型目录 |
| `container_model_path` | 传给服务启动脚本的容器内模型目录 |
| `served_model_id` | 服务启动后由 `/v1/models` 发现的模型 id |
| `bench_model_id` | 传给 `vllm bench serve --model` 的模型 id，默认使用 `served_model_id` |

注意：`host_model_path` 和 `container_model_path` 不要求字符串一致。以 GLM-4.7-W8A8 为例，
宿主机真实路径是 `/public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8`，
容器内有效路径是 `/model/GLM-4.7-W8A8`。

### ops

| 字段 | 说明 |
|---|---|
| `preflight_script` | 环境检查脚本 |
| `create_container_script` | 容器创建脚本 |
| `start_service_script` | vLLM 服务启动脚本 |
| `wait_ready_script` | 服务就绪等待和 `served_model_id` 发现脚本 |
| `run_bench_script` | 性能测试脚本路由器 |
| `stop_service_script` | 停止服务和端口释放验证脚本 |
| `render_report_script` | JSON/Markdown 报告生成脚本 |

## 测试模式参数

### full

| 字段 | 类型 | 说明 |
|---|---|---|
| `pairs` | list | 输入、输出、最大 batch 的组合 |
| `batch_seq` | list | 并发或 batch 序列 |

### pchit

| 字段 | 类型 | 说明 |
|---|---|---|
| `input_len` | int | 总输入长度 |
| `output_len` | int | 输出长度 |
| `cache_hit_pcts` | list | 目标命中率列表，如 `[50, 75, 90, 99]` |
| `batch_seq` | list | 并发列表 |
| `concurrency_multiplier` | int | 请求数倍率 |

### engin

| 字段 | 类型 | 说明 |
|---|---|---|
| `input_lens` | list | 输入长度列表 |
| `output_len` | int | 输出长度 |
| `batch_seq` | list | 并发或 batch 序列 |

### custom

| 字段 | 类型 | 说明 |
|---|---|---|
| `input_lens` | list | 输入长度列表 |
| `output_len` | int | 输出长度 |
| `concurrencies` | list | 并发列表 |
| `num_prompts_mult` | int | 请求数倍率，`num_prompts = concurrency * num_prompts_mult` |
| `request_rate` | float or null | 请求率，`null` 表示使用 `inf` |
| `percentiles` | string | 百分位列表，如 `"50,95,99"` |

## YAML 到脚本参数的映射

| `test.params` 字段 | 脚本环境变量 | 示例 |
|---|---|---|
| `pairs` | `PAIRS` | `PAIRS="512 512 128 1024 1024 64"` |
| `batch_seq` | `BATCH_SEQ` 或 `BATCHES` | `BATCH_SEQ="1 2 4 8"` |
| `input_lens` | `INPUT_LENS` | `INPUT_LENS="512 1024 2048"` |
| `output_len` | `OUTPUT_LEN` | `OUTPUT_LEN=256` |
| `cache_hit_pcts` | `CACHE_HIT_RATES` | `CACHE_HIT_RATES="50 75 90 99"` |
| `concurrencies` | `CONCURRENCIES` | `CONCURRENCIES="1 2 4 8"` |
| `num_prompts_mult` | `NUM_PROMPTS_MULT` | `NUM_PROMPTS_MULT=2` |
| `percentiles` | `PERCENTILES` | `PERCENTILES="50,95,99"` |

## 执行示例

```bash
export SERVED_MODEL_ID="/model/GLM-4.7-W8A8"
export INPUT_LENS="512 1024 2048"
export OUTPUT_LEN=256
export CONCURRENCIES="1 2 4 8"
export NUM_PROMPTS_MULT=2
bash scripts/client-scripts/run_perf_test-custom.sh "$SERVED_MODEL_ID" 9348 8
```

所有模式都应优先通过 `scripts/ops/run_bench.sh` 调用 client 脚本，避免直接拼接长命令。
调用 `run_bench.sh` 时必须传入 `--work-dir`，并建议同时传入 `--state`：

```bash
bash scripts/ops/run_bench.sh \
  --node 10.16.1.9 \
  --container <container_prefix>-0520-glm47int8-2540 \
  --test-mode custom \
  --served-model-id "/model/GLM-4.7-W8A8" \
  --port 9348 \
  --tp 8 \
  --work-dir "/mnt/skilltest/vllm-perf-validation-single/work_dirs/<run_id>" \
  --state "/mnt/skilltest/vllm-perf-validation-single/work_dirs/<run_id>/state.json"
```

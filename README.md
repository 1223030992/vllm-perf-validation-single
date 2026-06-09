# vllm-perf-validation-single

GitHub: <https://github.com/1223030992/vllm-perf-validation-single>

这是一个面向 Claude Code / Codex 的 vLLM 单节点性能验证 skill。它把模型性能测试拆成低自由度 ops 入口，统一完成容器创建、服务启动、`/v1/models` 发现 `served_model_id`、benchmark、停止服务、生成 CSV/JSON/Markdown 报告等闭环。

当前重点是：单模型 single 流程、新模型标准化注册、single custom、single pchit prefix cache benchmark。serial / parallel、多机多模型、sglang 扩展仍在规划或实验阶段。

## 快速导航

- [1. 新用户一键迁移](#1-新用户一键迁移)
- [2. 快速使用方式](#2-快速使用方式)
- [3. 路径替换](#3-路径替换)
- [4. 项目结构](#4-项目结构)
- [5. 状态示例与测试模式介绍](#5-状态示例与测试模式介绍)
- [6. 模型支持矩阵](#6-模型支持矩阵)
- [7. 功能测试矩阵](#7-功能测试矩阵)
- [8. 给 Claude 的标准指令](#8-给-claude-的标准指令)
- [9. pchit 流程说明](#9-pchit-流程说明)
- [10. 已验证案例](#10-已验证案例)
- [11. 常见问题处理](#11-常见问题处理)
- [12. 开发和验证](#12-开发和验证)

## 1. 新用户运行时配置

新用户拿到 skill 后，不需要先全仓替换用户名。正式注册和测试任务建议在主入口命令中直接传入 `--user <user> --abbr <abbr>`，运行时会自动推导宿主机 home、产物目录和容器名前缀，并在正式测试前检查/创建工作区。

默认运行时规则：

| 配置项 | 默认值 |
| --- | --- |
| skill 宿主机路径 | `/public/home/<user>/.claude/skills/vllm-perf-validation-single` |
| 运行产物路径 | `/public/home/<user>/skilltest/vllm-perf-validation-single` |
| 容器内 skill 路径 | `/mnt/.claude/skills/vllm-perf-validation-single` |
| 容器内产物路径 | `/mnt/skilltest/vllm-perf-validation-single` |
| 容器名前缀 | `<abbr>-agent-test` |

示例：`--user zhangsan --abbr zs` 后，容器名默认为 `zs-agent-test-<MMDD>-<MODEL_SHORT>-<IMAGE_PREFIX>`。

工作区检查规则：

- 已存在 `/public/home/<user>/skilltest/vllm-perf-validation-single`：不询问，直接继续。
- 不存在且任务带 `--assume-yes`：自动创建 `work_dirs/reports/logs/csvs/tmp`。
- 不存在且未授权 `--assume-yes`：只询问一次，确认后创建。

`configure_skill_user.sh` 仍保留为可选辅助工具，只用于需要把 README、示例、规则文件中的模板文本批量替换为个人路径的场景。日常注册和测试不依赖它，推荐直接在主入口命令里传 `--user <user> --abbr <abbr>`。

可选检查命令：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/configure_skill_user.sh \
  --from-user <old_user> \
  --from-container-prefix <old_prefix> \
  --user <user> \
  --abbr <abbr> \
  --dry-run
```

## 2. 快速使用方式

推荐使用方式不是手写远端命令，而是把标准化任务描述发给 Claude，让 Claude 只调用本项目 `scripts/ops/*.sh` 入口。

最小流程：

1. 替换路径：用户名、skill 安装目录、模型宿主机路径、产物目录。
2. 新模型先注册：标准化 server script，再注册 profile/example。
3. 测试模型：用户明确要求 dry-run 时才 dry-run；正式测试时只调用一次主入口。

必须遵守：

- 正式入口使用绝对路径，例如 `/public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh`。
- 不推荐相对路径入口、变量块入口、`DRY_RUN=... bash` 前缀入口。
- 不手写远端命令、容器命令、benchmark 命令或 API 探测命令绕过 ops 脚本。
- 不自动删除容器。`docker rm` 必须由用户明确点名容器后再处理。

## 3. 路径替换

README 的可执行模板统一使用 `<user>` 和 `<abbr>` 占位符。历史实测案例中的真实路径只用于追溯结果，不参与新用户运行配置。

| 路径类型 | 示例 | 说明 |
| --- | --- | --- |
| Git 工作区 | `/public/home/<user>/projects/vllm-perf-validation-single` | 代码仓库位置 |
| skill 安装目录 | `/public/home/<user>/.claude/skills/vllm-perf-validation-single` | Claude 实际调用的 skill 目录 |
| 产物目录 | `/public/home/<user>/skilltest/vllm-perf-validation-single` | `state.json`、CSV、报告、日志输出位置 |
| 模型宿主机路径 | `/public/opendas/DL_DATA/llm-models/...` | 计算节点真实模型目录 |
| 容器内模型路径 | `/model/...`、`/model1/...`、`/model2/...` | Docker 挂载后的容器内路径 |
| Claude 权限配置 | `.claude/settings.local.json` | 需要 allow 本项目 ops 入口 |

如果 skill 不是安装在 `/public/home/<user>/.claude/skills/`，所有 Claude 指令里的绝对路径都要同步替换。

## 4. 项目结构

```text
vllm-perf-validation-single/
├── README.md
├── SKILL.md
├── task.yaml
├── agents/
│   └── openai.yaml
├── references/
│   ├── conventions.md
│   ├── ops-templates.md
│   ├── usage-guide.md
│   ├── examples/
│   │   ├── glm47int8-test-task.yaml
│   │   ├── glm5int8-test-task.yaml
│   │   ├── kimik25int4-test-task.yaml
│   │   ├── minimaxm25int8-test-task.yaml
│   │   └── ...
│   ├── profiles/
│   │   ├── glm47int8.yaml
│   │   ├── glm5int8.yaml
│   │   ├── glm51int8.yaml
│   │   ├── kimik25int4.yaml
│   │   ├── minimaxm25int8.yaml
│   │   └── ...
│   ├── rules/
│   │   ├── eval-rules.md
│   │   ├── logging-rules.md
│   │   └── single-node-rules.md
│   └── schemas/
│       └── task.schema.json
└── scripts/
    ├── add-model.sh
    ├── client-scripts/
    │   ├── prefix_cache_benchmark.py
    │   ├── run_perf_test-custom.sh
    │   ├── run_perf_test-pchit-control.sh
    │   └── ...
    ├── ops/
    │   ├── run_single_task.sh
    │   ├── standardize_server_script.sh
    │   ├── register_model.sh
    │   ├── resume_single_task.sh
    │   ├── pchit_warmup.sh
    │   ├── pchit_log_parser.py
    │   ├── run_bench.sh
    │   ├── wait_vllm_ready.sh
    │   ├── stop_service.sh
    │   ├── render_report.py
    │   └── ...
    └── server-scripts/
        ├── run_glm4.7-w8a8-server.sh
        ├── run_glm47int8-server.sh
        ├── run_glm5-w8a8-server.sh
        ├── run_glm5.1-w8a8-server.sh
        ├── run_kimik2.5-int4-server.sh
        ├── run_minimax2.5-w8a8.sh
        └── ...
```

关键模块：

| 模块 | 作用 |
| --- | --- |
| `references/profiles/` | 模型 profile，记录路径、端口、TP、精度和 vLLM 参数 |
| `references/examples/` | 每个模型的测试任务示例 |
| `scripts/ops/` | Claude 应优先调用的稳定入口，负责状态机和闭环执行 |
| `scripts/server-scripts/` | 每个模型的 vLLM 服务启动脚本 |
| `scripts/client-scripts/` | 容器内 benchmark 客户端脚本 |
| `scripts/client-scripts/prefix_cache_benchmark.py` | 新 pchit 默认 benchmark 客户端 |
| `scripts/ops/pchit_warmup.sh` | 旧 pchit server-log 预热兼容入口，新测试不推荐 |

## 5. 状态示例与测试模式介绍

| 状态 | 含义 |
| --- | --- |
| ✅ stable | 稳定可复用，适合作 baseline |
| 🟢 passed | 已有真实冒烟或专项测试通过 |
| 🟡 registered | 已注册或已接入，但缺少真实测试 |
| 🟡 not tested | 已有配置，但该功能未实测 |
| 🟠 experimental | 有实现或示例，但仍需深测 |
| 🔴 blocked | 已知阻塞 |
| ⚪ planned | 待开发 |

| 测试模式 | 适用场景 | 当前建议 |
| --- | --- | --- |
| `custom` | 灵活组合 `input_lens`、`output_len`、`concurrencies`、请求数倍率和分位数，适合快速冒烟、baseline 和临时验证。 | 单模型优先使用，当前最稳定。 |
| `pchit` | 使用自研 prefix cache benchmark，通过共享前缀和随机后缀构造指定 PC 命中率，适合需要稳定控制 prefix cache hit 的长上下文场景。 | 已完成 GLM-4.7 fixed / SLA-search 实测，推荐用于 PC 命中率专项测试。 |
| `full` | 覆盖更完整的输入/输出/并发组合，适合周期性回归或全面性能摸底。 | 参数组合多，执行前建议先用 `custom` 冒烟。 |
| `engin` | 面向固定输出长度和引擎侧能力验证的测试入口，适合对齐已有 `run_perf_test-engin.sh` 规则。 | 已有脚本，仍需更多真实回归。 |
| `serial` / `parallel` | 多模型串行或并行调度验证，关注容器生命周期、端口释放和多任务隔离。 | 实验性，暂不作为稳定回归入口。 |

## 6. 模型支持矩阵

| 模型 | MODEL_SHORT | 端口 | TP | 精度 | custom | pchit fixed | pchit SLA-search | serial / parallel | 总状态 | 案例 |
| --- | --- | ---: | ---: | --- | --- | --- | --- | --- | --- | --- |
| GLM-4.7-W8A8 | `glm47int8` | 9348 | 8 | int8 | <span title="stable">✅</span> | <span title="passed">🟢</span> | <span title="passed">🟢</span> | <span title="experimental">🟠</span> | <span title="stable">✅</span> | [custom](#101-glm-47-w8a8-single-custom-baseline), [fixed](#104-glm-47-w8a8-pchit-fixed), [SLA-search](#105-glm-47-w8a8-pchit-sla-search) |
| GLM-5-W8A8 | `glm5int8` | 9349 | 8 | int8 | <span title="not retested">🟡</span> | <span title="not tested">🟡</span> | <span title="not tested">🟡</span> | <span title="experimental">🟠</span> | <span title="integrated / needs retest">🟡</span> | - |
| GLM-5.1-Channel-INT8 | `glm51int8` | 9350 | 8 | int8 | <span title="not retested">🟡</span> | <span title="historical passed">🟢</span> | <span title="not retested">🟡</span> | <span title="experimental">🟠</span> | <span title="integrated / needs retest">🟡</span> | [historical pchit](#103-glm-51-channel-int8-pchit-历史冒烟) |
| MiniMax-M2.5-W8A8 | `minimaxm25int8` | 9352 | 8 | int8 | <span title="not tested">🟡</span> | <span title="not tested">🟡</span> | <span title="not tested">🟡</span> | <span title="experimental">🟠</span> | <span title="registered">🟡</span> | - |
| Kimi-K2.5-INT4 | `kimik25int4` | 9354 | 8 | int4 | <span title="passed">🟢</span> | <span title="not tested">🟡</span> | <span title="not tested">🟡</span> | <span title="experimental">🟠</span> | <span title="passed">🟢</span> | [custom](#102-kimi-k25-int4-single-custom-冒烟) |

说明：`model.precision` 表示模型/权重量化精度；`service.vllm_params.dtype` 表示计算 dtype；`kv_cache_dtype` 表示 KV cache 精度。Kimi 的模型精度为 `int4`，计算 dtype 为 `bfloat16`，KV cache 为 `fp8_e4m3`。

## 7. 功能测试矩阵

| 功能 | 状态 | 已验证范围 | 说明 |
| --- | --- | --- | --- |
| single custom | <span title="stable">✅</span> | GLM-4.7、Kimi | 主链路已可复用 |
| 新模型标准化注册 | <span title="usable">🟢</span> | MiniMax、Kimi | 支持标准化 server script、注册 profile/example、输出 dry-run |
| single pchit fixed | <span title="passed">🟢</span> | GLM-4.7 | 使用自研 `prefix_cache_benchmark.py`，完整跑并发列表 |
| single pchit SLA-search | <span title="passed">🟢</span> | GLM-4.7 | 遇到首个 SLA FAIL 停止并输出 best concurrency |
| `/v1/models` served_model_id 发现 | <span title="passed">🟢</span> | GLM-4.7、GLM-5.1、Kimi | benchmark 使用服务实际返回的 model id |
| `resume_single_task.sh` | <span title="partial / needs more validation">🟠</span> | readiness 后恢复路径 | 已有入口，仍需更多中断场景验证 |
| serial | <span title="experimental">🟠</span> | 示例和规则存在 | 未标记稳定 |
| parallel | <span title="experimental">🟠</span> | 示例和规则存在 | 未标记稳定 |
| 非 GLM pchit | <span title="not tested">🟡</span> | - | Kimi / MiniMax 尚未实测 pchit |
| 多机多模型模式 | <span title="planned">⚪</span> | - | 待开发 |
| sglang 模型扩展 | <span title="planned">⚪</span> | - | 待开发 |

## 8. 给 Claude 的标准指令

下面模板用于复制给 Claude。模板中的 `<user>`、`<abbr>`、节点、镜像、路径和端口要替换为实际值。

### 8.1 现有模型 profile 模式

如果模型已在 `references/profiles/` 中注册，优先使用 `--profile <MODEL_SHORT>`。这样 Claude 不需要读取 profile、列目录或手工拼模型路径。

```text
/vllm-perf-validation-single

请只调用一条绝对路径主入口 run_single_task.sh，并使用 --profile <MODEL_SHORT> 自动读取已注册模型信息。

用户配置：
user: <user>
abbr: <abbr>

要求：
1. 不要读取 profile 文件。
2. 不要单独执行 preflight。
3. 不要手写远端命令、容器命令、benchmark 命令或 API 探测命令。
4. server script 由 profile 自动解析，必须保持相对路径形式。
5. 只有我明确要求 dry-run 时才加 --dry-run。
```

### 8.2 新模型标准化注册

```text
/vllm-perf-validation-single

请为新增模型执行标准化注册流程，不执行真实 SSH/Docker/GPU 测试。

模型信息：
user: <user>
abbr: <abbr>
model_name: <MODEL_NAME>
model_short: <MODEL_SHORT>
host_model_path: <HOST_MODEL_PATH>
container_model_path: <CONTAINER_MODEL_PATH>
server_script: /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/<SCRIPT_NAME>
port: <PORT>（推荐显式提供；不提供时注册器会按已注册端口最大值 + 1 自动分配）
tp: <TP>
gpu_range: <GPU_RANGE>
precision: <MODEL_PRECISION>

要求：
1. 只能调用绝对路径入口：
   bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/standardize_server_script.sh ... --user <user> --abbr <abbr>
   bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh ... --user <user> --abbr <abbr>
2. 先执行 standardize_server_script.sh --dry-run，确认 diff。
3. dry-run 无误后正式标准化 server script。
4. 再执行 register_model.sh --dry-run。
5. register_model dry-run 无 WARN 后正式注册。
6. 不手写 profile/example。
7. 输出生成的 profile/example 路径和 run_single_task.sh --dry-run 命令。
```

### 8.3 single custom 冒烟测试

```text
/vllm-perf-validation-single

我授权你执行 single custom 冒烟测试。

参数：
node: <NODE>
image: <IMAGE>
profile: <MODEL_SHORT>
user: <user>
abbr: <abbr>
gpu_range: 0,1,2,3,4,5,6,7
test_mode: custom
input_lens: 512
output_len: 32
concurrencies: 1
num_prompts_mult: 1
percentiles: 50,95,99
timeout: 2400

要求：
1. 只允许调用一次主入口：
   bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh ... --user <user> --abbr <abbr>
2. 不要执行 --help。
3. 不要读取 profile 文件，不要 ls/grep/cat/docker ps/tee/tail/python 解析 state。
4. 不要单独 preflight。
5. benchmark 必须使用 /v1/models 返回的 served_model_id。
6. 结束后停止容器，生成 state.json、CSV、JSON、Markdown 报告并汇总主入口 stdout 中的路径。
7. 禁止 docker rm。
```

### 8.4 pchit fixed 测试

```text
/vllm-perf-validation-single

我授权你执行 single pchit fixed 测试。

参数：
node: <NODE>
image: <IMAGE>
profile: <MODEL_SHORT>
user: <user>
abbr: <abbr>
gpu_range: 0,1,2,3,4,5,6,7
test_mode: pchit
input_len: 32768
output_len: 1024
batches: 1,2,3,4,5,6,7,8
concurrency_multiplier: 1
pc_hit_target: 90
pchit_benchmark_mode: fixed
ttft_sla_ms: 5000
tpot_sla_ms: 50
sla_stat: mean
prefix_warmup_requests: 1
case_warmup_repeats: 0
timeout: 3600

要求：
1. 只允许调用一次 run_single_task.sh 主入口。
2. pchit 必须使用自研 prefix_cache_benchmark.py。
3. 不允许调用旧 pchit_warmup.sh。
4. 不要执行 --help。
5. 不要 dry-run，除非我明确要求。
6. 不要 ls/grep/cat/docker ps/tee/tail/python 解析 state。
7. 只根据 run_single_task.sh 的 stdout 汇总结果。
8. 禁止 docker rm。
```

### 8.5 pchit SLA-search 测试

```text
/vllm-perf-validation-single

我授权你执行 GLM-4.7-W8A8 single pchit SLA-search 测试。

硬性要求：
1. 只允许调用一次主入口：
   bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh ... --user <user> --abbr <abbr>
2. 不允许执行 dry-run。
3. 不允许执行 --help。
4. 不允许 ls、grep、cat、docker ps、tee、tail、python 解析 state。
5. 不允许读取 profile 文件。
6. 不允许单独 preflight。
7. 不允许手写 ssh/docker/vllm bench/curl/API 探测命令。
8. 只能根据 run_single_task.sh 的 stdout 汇总结果。
9. 如果主入口失败，直接汇报失败原因，不允许手写命令补救。
10. 禁止 docker rm。

参数：
node: 10.16.1.7
image: 10.16.1.254:5000/jenkins/model_test_env/vllm:daily-20260428-1927
profile: glm47int8
user: <user>
abbr: <abbr>
gpu_range: 0,1,2,3,4,5,6,7
test_mode: pchit
input_len: 32768
output_len: 1024
batches: 1,2,3,4,5,6,7,8
concurrency_multiplier: 1
pc_hit_target: 90
pchit_benchmark_mode: sla-search
ttft_sla_ms: 5000
tpot_sla_ms: 50
sla_stat: mean
prefix_warmup_requests: 1
case_warmup_repeats: 0
timeout: 3600
```

Claude 唯一应执行的命令形态：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh \
  --user <user> \
  --abbr <abbr> \
  --profile glm47int8 \
  --node 10.16.1.7 \
  --image 10.16.1.254:5000/jenkins/model_test_env/vllm:daily-20260428-1927 \
  --gpu-range 0,1,2,3,4,5,6,7 \
  --test-mode pchit \
  --input-len 32768 \
  --output-len 1024 \
  --batches 1,2,3,4,5,6,7,8 \
  --concurrency-multiplier 1 \
  --pc-hit-target 90 \
  --pchit-benchmark-mode sla-search \
  --ttft-sla-ms 5000 \
  --tpot-sla-ms 50 \
  --sla-stat mean \
  --prefix-warmup-requests 1 \
  --case-warmup-repeats 0 \
  --timeout 3600 \
  --assume-yes
```

### 8.6 SERVICE_TIMEOUT 后恢复

```text
/vllm-perf-validation-single

上一次 run_single_task.sh 在 readiness 或后续阶段中断。请只使用 resume_single_task.sh 按 state 恢复，不创建新容器，不重新启动服务，不手写补救命令。

state: <STATE_JSON_PATH>

要求：
1. 只能调用绝对路径 resume_single_task.sh。
2. 如果是 pchit，继续 run_bench 阶段即可；新流程不再强制恢复 pchit_warmup。
3. 最终停止服务并生成 JSON/Markdown 报告。
```

## 9. pchit 流程说明

pchit 默认使用自研 `scripts/client-scripts/prefix_cache_benchmark.py`。它不再把 server log 中的实时 PC 命中率作为准入门槛，而是通过“共享 prefix + 随机 suffix”构造指定 prefix cache hit 场景，并直接统计 TTFT、TPOT、ITL、吞吐和 SLA 结果。

推荐策略：

- 正式目标：`pc_hit_target=90`
- 输入输出：用 `--input-len` / `--output-len` 指定，例如 `32768 / 1024`
- 并发列表：用 `--batches` 指定，例如 `1,2,3,4,5,6,7,8`
- 请求数：`num_prompts = concurrency * concurrency_multiplier`
- fixed 模式：完整跑完指定并发列表
- SLA-search 模式：按 TTFT/TPOT SLA 搜索最大达标并发，遇到首个 FAIL 停止
- 默认 SLA：`ttft_sla_ms=5000`，`tpot_sla_ms=50`，`sla_stat=mean`

旧的 `pchit_warmup.sh` 和 `run_perf_test-pchit-control.sh` 保留为历史兼容入口，不作为新测试推荐路径。

## 10. 已验证案例

### 10.1 GLM-4.7-W8A8 single custom baseline

- 模式：single custom
- input/output：`512 / 32`
- 状态：✅ stable
- 说明：preflight、create、start、wait、bench、stop、report 主链路已稳定，适合作为新环境 baseline。

### 10.2 Kimi-K2.5-INT4 single custom 冒烟

- 节点：`10.16.1.9`
- 端口：`9354`
- served_model_id：`/model/Kimi-K2.5`
- 状态：🟢 passed，容器已停止，端口已释放
- ready 耗时：约 `1200s`
- QPS：`0.98 req/s`
- 输出 token 吞吐：`31.33 tok/s`
- 总 token 吞吐：`532.65 tok/s`

示例产物路径：

- `state.json`：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs/Kimi-K2.5-INT4-custom-20260522-lzh-agent-test-0522-kimik25int4-2540/state.json`
- CSV：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs/Kimi-K2.5-INT4-custom-20260522-lzh-agent-test-0522-kimik25int4-2540/csvs/custom/all.csv`
- JSON 报告：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/reports/kimik25int4-custom-20260522-lzh-agent-test-0522-kimik25int4-2540.json`
- Markdown 报告：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/reports/kimik25int4-custom-20260522-lzh-agent-test-0522-kimik25int4-2540.md`

补充：`10.16.1.4` 上一次尝试因 GPU 显存已有占用，进程退出 `137`，不视为 Kimi 注册流程失败。

### 10.3 GLM-5.1-Channel-INT8 pchit 历史冒烟

- 节点：`10.16.1.9`
- 镜像：`10.16.1.152:5000/jenkins/model_test_env/vllm:0.15.1-ubuntu22.04-dtk26.04-py3.10-20260515-1239`
- profile：`glm51int8`
- 模式：single pchit，旧 server-log 预热达标流程
- 端口：`9350`
- served_model_id：`/model1/GLM-5.1-Channel-INT8`
- 状态：🟢 historical passed，最终 `STOPPED`，端口已释放
- 权限表现：只调用一条绝对路径主入口，无额外权限询问

测试配置：

- input/output：`2048 / 1024`
- batches：`1,2,3,4,5,6,7,8`
- 目标命中率：`pc_hit_target=90`
- 预热结果：observed PC hit 为 `89.6%`，使用 `95%` warmup 达标
- 预热轮次：`2`
- 预热耗时：`3060s`

该案例来自旧 server-log 预热达标流程。当前默认 pchit 已切换为自研 `prefix_cache_benchmark.py`，该历史结果只作为路径闭环和权限配置参考。

### 10.4 GLM-4.7-W8A8 pchit fixed

- 节点：`10.16.1.7`
- 镜像：`10.16.1.152:5000/jenkins/model_test_env/vllm:0.15.1-ubuntu22.04-dtk26.04-py3.10-20260520-0849`
- profile：`glm47int8`
- 模式：single pchit fixed
- input/output：`32768 / 1024`
- target：`90%`
- effective：`89.9902%`
- prefix_len：`29488`
- 并发列表：`bs=1..8` 完整跑完
- best SLA concurrency：`5`
- 状态：🟢 passed，`bs=6/7/8` 为 SLA FAIL，不是服务失败
- 请求：completed `36`，failed `0`

核心结果：

| bs | mean TTFT ms | mean TPOT ms | output tok/s | total tok/s | SLA |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1 | 1214.65 | 10.75 | 83.88 | 2768.13 | PASS |
| 2 | 2170.47 | 17.00 | 92.46 | 3051.25 | PASS |
| 3 | 3207.53 | 19.55 | 115.51 | 3811.94 | PASS |
| 4 | 3633.36 | 21.10 | 149.44 | 4931.56 | PASS |
| 5 | 4515.58 | 22.73 | 173.36 | 5720.84 | PASS |
| 6 | 5461.63 | 26.97 | 163.28 | 5388.34 | FAIL |
| 7 | 6480.25 | 27.67 | 191.74 | 6327.42 | FAIL |
| 8 | 7382.48 | 27.33 | 214.37 | 7074.11 | FAIL |

产物路径：

- `state.json`：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs/GLM-4.7-W8A8-pchit-20260608-lzh-agent-test-0608-glm47int8-30fb/state.json`
- CSV：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs/GLM-4.7-W8A8-pchit-20260608-lzh-agent-test-0608-glm47int8-30fb/csvs/pchit/all.csv`
- Prefix JSON：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs/GLM-4.7-W8A8-pchit-20260608-lzh-agent-test-0608-glm47int8-30fb/csvs/pchit/prefix_cache_benchmark.json`
- JSON 报告：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/reports/glm47int8-pchit-20260608-lzh-agent-test-0608-glm47int8-30fb.json`
- Markdown 报告：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/reports/glm47int8-pchit-20260608-lzh-agent-test-0608-glm47int8-30fb.md`

### 10.5 GLM-4.7-W8A8 pchit SLA-search

- 节点：`10.16.1.7`
- 镜像：`10.16.1.254:5000/jenkins/model_test_env/vllm:daily-20260428-1927`
- profile：`glm47int8`
- 模式：single pchit SLA-search
- input/output：`32768 / 1024`
- target：`90%`
- effective：`89.9902%`
- prefix_len：`29488`
- SLA-search 在 `bs=7` FAIL 后停止
- best SLA concurrency：`6`
- 请求：completed `28`，failed `0`
- 状态：🟢 passed

核心结果：

| bs | mean TTFT ms | mean TPOT ms | output tok/s | total tok/s | SLA |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1 | 1210.96 | 12.66 | 72.28 | 2385.24 | PASS |
| 2 | 2165.98 | 16.18 | 102.09 | 3369.03 | PASS |
| 3 | 2667.00 | 19.91 | 123.13 | 4063.21 | PASS |
| 4 | 3630.97 | 20.67 | 153.05 | 5050.56 | PASS |
| 5 | 4097.55 | 22.53 | 173.85 | 5736.98 | PASS |
| 6 | 4911.92 | 25.96 | 174.95 | 5773.34 | PASS |
| 7 | 6432.26 | 25.73 | 205.66 | 6786.67 | FAIL |

产物路径：

- `state.json`：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs/GLM-4.7-W8A8-pchit-20260608-lzh-agent-test-0608-glm47int8-2540/state.json`
- CSV：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs/GLM-4.7-W8A8-pchit-20260608-lzh-agent-test-0608-glm47int8-2540/csvs/pchit/all.csv`
- Prefix JSON：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs/GLM-4.7-W8A8-pchit-20260608-lzh-agent-test-0608-glm47int8-2540/csvs/pchit/prefix_cache_benchmark.json`
- JSON 报告：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/reports/glm47int8-pchit-20260608-lzh-agent-test-0608-glm47int8-2540.json`
- Markdown 报告：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/reports/glm47int8-pchit-20260608-lzh-agent-test-0608-glm47int8-2540.md`

fixed 和 SLA-search 的 best concurrency 可因运行波动不同。正式结论建议多轮验证，或采用保守值。

## 11. 常见问题处理

| 问题 | 推荐处理 |
| --- | --- |
| Claude 权限询问过多 | 正式测试 prompt 必须禁止探索命令，只允许一次 `run_single_task.sh`；settings allow 不要放宽到 `ls/cat/docker ps/tee` |
| Claude 先读 profile 或 help | prompt 中明确禁止读取 profile、禁止 `--help`、禁止 `ls/grep` |
| 正式测试变成先 dry-run | prompt 中明确“不允许 dry-run，除非我明确要求” |
| server script 端口不对 | 标准化脚本必须使用 `--port ${PORT}`，避免落到默认 8000 |
| benchmark 404 | 必须用 `/v1/models` 返回的 `served_model_id` 作为 bench model |
| readiness 超时 | 使用 `resume_single_task.sh --state <state.json>` 继续，不手写补救命令 |
| 容器名冲突 | 不自动删除容器；由用户确认后处理或换规范容器名 |
| pchit benchmark 失败 | 检查目标镜像内是否可 `import aiohttp`，以及 CSV 中 `status/error_reason/sla_pass` 字段 |
| fixed 与 SLA-search 结果不一致 | 长输入测试有波动；fixed 完整跑列表，SLA-search 遇首个 FAIL 停止；建议多轮验证或取保守并发 |
| host model path preflight WARN | 如果容器内模型路径可用但 host path 检查失败，当前可继续成功；后续需要加固 preflight 的 WARN/FAIL 语义 |
| CSV 缺失 | 不生成虚假报告；应让 ops 脚本返回 `bench_csv_missing` |
| 精度记录混淆 | `model.precision` 记录权重量化精度；`dtype` 记录计算精度；`kv_cache_dtype` 单独记录 |

## 12. 开发和验证

本地静态检查建议：

```text
python -m py_compile scripts/client-scripts/prefix_cache_benchmark.py scripts/ops/register_model.py scripts/ops/standardize_server_script.py scripts/ops/pchit_log_parser.py scripts/ops/render_report.py scripts/ops/show_state.py scripts/ops/update_state.py
```

真实节点测试需要用户单独授权。默认开发和文档修改不执行 SSH/Docker/GPU 操作。

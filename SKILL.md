---
name: vllm-perf-validation-single
description: >
  在单个 DCU/GPU 节点上执行 vLLM 推理性能验证。适用于发布前性能回归、
  单模型/串行/并行验证、Prefix Cache 命中率测试、Prefill 测试、
  自定义 vllm bench serve 场景，以及为 vLLM DCU 性能测试流程新增模型配置。
---

# vLLM DCU 性能验证

使用本 Skill 在单个 DCU/GPU 节点上执行可审计、可复现的 vLLM 性能验证。
优先使用 `scripts/ops/` 中的低自由度脚本，不要手写很长的 SSH、Docker
或 `vllm bench serve` 命令。单模型 `custom` 冒烟和回归任务必须使用
`bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh ... --user <user> --abbr <abbr>`
作为正式自动化入口，把多次权限询问收敛为一次稳定脚本调用。不要先单独执行
`preflight_node.sh`，因为主入口已经内置 preflight。不要使用
`cd /public/... && bash scripts/ops/run_single_task.sh ...`、`DRY_RUN=1 bash ...`、
多行 Bash 变量块或相对路径入口。

## 目录速览

```text
SKILL.md                         # 入口文件，只保留流程、硬规则和引用导航
│
├─ references/                    # 按需加载的领域规则和示例
│  ├─ conventions.md              # 命名、端口、MODEL_SHORT 映射
│  ├─ usage-guide.md              # 面向用户的完整使用技术文档和实例
│  ├─ ops-templates.md            # Docker、服务启动和排障命令模板参考
│  ├─ profiles/                   # 模型默认配置和资源参数，新增模型优先由 register_model.sh 生成
│  ├─ rules/                      # 执行规则、评测规则、日志分类
│  ├─ schemas/                    # task/report 配置结构说明
│  └─ examples/                   # single/serial/parallel/custom 示例任务
│
├─ scripts/                       # 可执行脚本，优先使用而不是手写长命令
│  ├─ ops/                        # 核心状态机脚本：检查、创建、启动、等待、测试、停止、报告
│  ├─ server-scripts/             # 各模型 vLLM 服务启动脚本
│  ├─ client-scripts/             # full/pchit/engin/custom 性能测试脚本
│  └─ add-model.sh                # 旧版新增模型生成器；新流程优先使用 scripts/ops/register_model.sh
│
├─ task.yaml                      # 可直接执行的默认任务配置
└─ agents/openai.yaml             # Codex UI 展示信息和触发策略
```

新增模型时，优先运行绝对路径入口
`bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh ... --user <user> --abbr <abbr>`
生成 `references/profiles/<MODEL_SHORT>.yaml`、`references/examples/<MODEL_SHORT>-test-task.yaml`
和 `references/conventions.md` 映射。不要手写 profile/example，不要手写容器名。
`scripts/add-model.sh` 仅作为旧版兼容入口，现代参数会委托给 `register_model.sh`。

## 核心规则

- 以下高风险操作必须先向用户确认：首次 SSH 到新节点、创建容器、占用
  GPU/DCU、占用端口、拉取镜像、停止容器、删除容器。
- 除非用户明确点名容器并要求删除，否则永远不要执行 `docker rm`。不要把
  “清理”“释放”“重启”理解为删除授权。
- 只能使用用户或 `task.yaml` 指定的镜像。镜像缺失时必须询问用户，不要从
  `docker images` 中自行挑选。
- 服务启动后必须读取 `/v1/models`，用返回的模型 id 作为健康检查和性能测试
  的模型身份。不要假设展示名或路径就是 `served_model_id`。
- Serial 模式必须按状态机执行：完成性能测试、停止服务、验证进程和端口释放，
  然后才能启动下一个模型。
- 运行产物必须写入产物根目录，不要写入 Skill 安装包目录。

## 路径约定

Skill 文件和运行产物使用不同根目录：

| 用途 | 宿主机路径 | 容器内路径 |
|---|---|---|
| Skill 文件 | `/public/home/<user>/.claude/skills/vllm-perf-validation-single` | `/mnt/.claude/skills/vllm-perf-validation-single` |
| 运行产物 | `/public/home/<user>/skilltest/vllm-perf-validation-single` | `/mnt/skilltest/vllm-perf-validation-single` |
| 主模型目录 | `/public/opendas/DL_DATA/llm-models` | `/model` |
| 备用模型目录 | `/public4/share` | `/model1` |
| 第三模型目录 | `/public4/opendas/DL_DATA` | `/model2` |
| DCU 工具 | `/opt/hyhal` | `/opt/hyhal` |

创建容器时必须挂载 `/public/home/<user>:/mnt`，并挂载上表中的模型目录和工具目录。正式任务应显式传入 `--user <user> --abbr <abbr>`；主入口会由此推导 `HOST_HOME_ROOT`、`OUTPUT_HOST_ROOT` 和容器名前缀。

## 模型身份

任务、profile、报告和状态文件中必须区分以下字段：

| 字段 | 含义 |
|---|---|
| `host_model_path` | preflight 阶段在宿主机上检查的模型目录 |
| `container_model_path` | 传给服务启动脚本的容器内模型目录 |
| `served_model_id` | 服务启动后通过 `GET /v1/models` 发现的模型 id |
| `bench_model_id` | 传给 `vllm bench serve --model` 的模型 id，默认等于 `served_model_id` |

在当前环境中，GLM-4.7-W8A8 的宿主机真实路径是
`/public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8`，但容器内有效路径是
`/model/GLM-4.7-W8A8`。二者可以不同；性能测试前必须以 `/v1/models`
发现到的 `served_model_id` 为准。

## 执行模式

- `single`：一个模型独占 8 张 GPU/DCU。
- `serial`：多个模型按顺序执行，每次只运行一个服务。
- `parallel`：两个 4 卡服务同时运行，必须使用互不重叠的 `GPU_RANGE`。

测试模式与执行模式相互独立：

- `full`：发布基准矩阵。
- `pchit`：Prefix Cache 命中率测试。
- `engin`：Prefill 侧重点测试。
- `custom`：用户自定义输入、输出和并发矩阵。

## 必须流程

1. 读取 `task.yaml` 或对应的 `references/examples/*.yaml`。
2. 读取 `references/conventions.md`，确定 `MODEL_SHORT`。
3. 按需读取 `references/profiles/` 下的模型默认配置。
4. 单模型 `custom` 任务必须调用绝对路径 `scripts/ops/run_single_task.sh`；该脚本会串联
   `ensure_workspace.sh -> preflight_node.sh -> create_container.sh -> start_vllm_service.sh -> wait_vllm_ready.sh -> run_bench.sh -> render_report.py -> stop_service.sh -> render_report.py -> show_state.sh`。
5. 如果用户明确要求诊断模式，才允许手动分步调用 `scripts/ops/*.sh`；不要手写 SSH/Docker/vLLM 长命令。
6. benchmark 完成后先生成一次报告，再停止容器；stop 成功或失败后重新生成最终报告。

如果 ops 脚本缺少能力，优先补齐脚本，不要绕过流程去拼长命令。

## Ops 执行纪律

- 执行真实测试时必须优先调用 `scripts/ops/` 中的状态机脚本。不要手写 `docker run`、`docker exec`
  长命令、readiness 轮询循环、client benchmark 命令或 `docker stop`。
- 单模型 `custom` 任务优先使用绝对路径入口
  `bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh ... --user <user> --abbr <abbr> --assume-yes`；
  当用户已在 prompt 中明确授权时，不要再拆成多条 Bash 变量块分别执行。
- dry-run 也必须使用主入口参数 `--dry-run`，不要使用环境变量前缀
  `DRY_RUN=1 bash ...` 或 `DRY_RUN=0 bash ...`，否则无法匹配 Claude Code allow 规则。
- 如果某个 ops 脚本失败，应停止当前自动流程，汇报脚本名、参数、错误输出和建议修复点；不要临时改写一段新的
  SSH/Docker 命令继续推进。
- 如果 `run_single_task.sh` 在 stop/report 阶段失败，只能使用它输出的
  `scripts/ops/recover_single_task.sh` 恢复入口继续处理，不要手写 `ssh docker stop`。
- 涉及 `vllm`、`torch`、`vllm bench serve` 的容器内命令必须通过 ops 脚本使用 `bash -ic` 执行。
  普通 `bash -c` 可能缺少 DTK/HIP 环境并触发 `libgalaxyhip.so.5`、`librocm_smi64.so.2` 等缺库错误。
- `scripts/client-scripts/*.sh` 是底层 client 适配脚本，不是主流程入口。性能测试应通过
  `scripts/ops/run_bench.sh` 执行，以保证 `served_model_id`、`state.json`、CSV 路径和失败原因被记录。
- 所有输出路径应同时记录容器路径和宿主机路径。容器停止后，读取结果时应使用
  `/public/home/<user>/skilltest/vllm-perf-validation-single/...`，不要在宿主机直接读取 `/mnt/skilltest/...`。

## Serial 状态机

Serial 模式必须按以下顺序处理每个模型：

```text
PREFLIGHT
CREATE_CONTAINER(model_i)
START_SERVICE(model_i)
WAIT_READY(model_i)
DISCOVER_SERVED_MODEL_ID(model_i)
RUN_BENCH(model_i)
STOP_SERVICE(model_i)
VERIFY_RELEASE(model_i)
NEXT_MODEL
FINAL_REPORT
```

`VERIFY_RELEASE(model_i)` 成功前，不能启动 `model_i+1`。

## 就绪日志分类

以下日志表示等待、加载或编译中，不是失败：

- `Loading safetensors checkpoint shards`
- `torch.compile takes`
- `No available shared memory broadcast block found`
- `Initializing moe_cache_singleton`
- `hipModuleLoad ... Success`
- `Please install aiter if you want to infer with aiter_moe`
- `bash: cannot set terminal process group`
- `bash: no job control in this shell`

完整规则见 `references/rules/log-classification.md`。出现 `Traceback`、`ImportError`、
`RuntimeError`、`Killed`、`OOM`、服务进程退出或等待超时时，应判定为失败。

## 参考资料

只加载当前任务需要的引用文件：

| 需求 | 引用文件 |
|---|---|
| 完整使用说明和操作实例 | `references/usage-guide.md` |
| 命名、端口、模型简称 | `references/conventions.md` |
| Docker 和服务命令模板 | `references/ops-templates.md` |
| 部署和就绪规则 | `references/rules/deployment-rules.md` |
| single/serial/parallel 规则 | `references/rules/single-node-rules.md` |
| 性能测试模式和指标 | `references/rules/evaluation-rules.md` |
| 日志严重级别分类 | `references/rules/log-classification.md` |
| 任务配置 schema | `references/schemas/task-config-schema.md` |
| 报告 schema | `references/schemas/report-schema.md` |
| 任务示例 | `references/examples/*.yaml` |

## 新增模型

使用 `scripts/ops/register_model.sh` 注册新的模型启动脚本。该脚本只修改本地 skill 文件，
不会连接 SSH、Docker 或 GPU。必须提供 `--model-name`、`--host-model-path`、`--server-script`；
Qwen、DeepSeek 等非 GLM 模型还必须显式提供 `--port`。脚本会自动推导 `MODEL_SHORT`、
容器路径、GLM 默认端口，并输出可直接执行的 `run_single_task.sh --dry-run` 命令。

示例：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh \
  --user <user> \
  --abbr <abbr> \
  --model-name GLM-5-W8A8 \
  --host-model-path /public/opendas/DL_DATA/llm-models/vllm-w8a8-models/GLM-5-W8A8 \
  --server-script /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/run_glm5-w8a8-server.sh \
  --dry-run
```

正式注册前先 `--dry-run`。确认无误后去掉 `--dry-run`；已有 profile/example 时必须显式传
`--overwrite` 才会覆盖。

## 输出要求

每次运行应留下：

- `work_dirs/<run_id>/state.json`
- `work_dirs/<run_id>/logs/*`
- `work_dirs/<run_id>/csvs/<test_mode>/all.csv`
- `reports/<run_id>.json`
- `reports/<run_id>.md`

报告必须包含节点、镜像、容器、`host_model_path`、`container_model_path`、
`served_model_id`、性能指标、启动耗时、就绪检查耗时、GPU/DCU 拓扑、
失败原因和 baseline 状态。

## 闭环规则补充

- `GLM-5-W8A8` 默认 readiness timeout 为 `3600` 秒，避免首次 `torch.compile` 和 CUDA graph capture 误判超时。
- 如果 `run_single_task.sh` 已创建容器并启动服务，但在 `WAITING_READY` / `SERVICE_TIMEOUT` 前后中断，必须使用
  `bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/resume_single_task.sh --state ...`
  继续 `wait -> bench -> report -> stop -> final report -> show_state`。不要手写 `curl`、`run_bench.sh`、`docker stop` 或手造 CSV。
- `recover_single_task.sh` 只用于 benchmark 已完成后的 stop/report 恢复；没有 CSV 的状态应使用 `resume_single_task.sh`。
- 新增非 GLM 模型时，`register_model.sh` 不再默认 `TP=8`。必须显式传 `--tp`，或由 server script 中的 `-tp 2`、
  `--tensor-parallel-size 2`、`export TP_SIZE=2`、`export TP=2` 推导。若推导出 `TP=2` 且未传 `--gpu-range`，默认 `GPU_RANGE=0,1`。
- 正式注册非参数化 server script 默认失败；只有显式传 `--allow-static-server-script` 才允许保留静态脚本。
## 新模型标准化

新增模型时优先按以下顺序执行：

1. 使用绝对路径入口 `standardize_server_script.sh --dry-run` 检查 server script 标准化 diff。
2. 去掉 `--dry-run` 标准化 server script。
3. 使用 `register_model.sh --dry-run` 检查 profile/example 和 `run_single_task.sh --dry-run` 命令。
4. 正式注册后再用 `run_single_task.sh` 做 single custom 冒烟。

标准化入口：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/standardize_server_script.sh ... --user <user> --abbr <abbr>
```

标准化后的 server script 必须使用 `MODEL_PATH`、`PORT`、`TP_SIZE`、`GPU_RANGE` 变量，不要保留硬编码模型路径、端口、TP 或 GPU 列表。`register_model.sh` 发现未标准化脚本时会输出 `NEXT_STEP_STANDARDIZE_CMD`，正式注册默认失败；只有用户明确接受静态脚本时才传 `--allow-static-server-script`。

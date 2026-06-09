# 单节点规则

本文件定义单节点 vLLM 性能验证的执行规则，包括 Serial 和 Parallel 两种模式。

---

## 0. 核心硬规则（必须遵守）

### Serial 模式硬规则

**同一时间只允许一个 8 卡 vLLM 服务运行。违反以下规则将导致测试失败：**

1. **启动下一个模型前，必须停止上一个模型的服务或容器**
   - 必须确认：端口释放、vLLM 进程退出
   - 检查命令（宿主机执行）：`ssh <NODE> "pgrep -af 'vllm serve' && exit 1 || true"` 应返回成功（空结果）

2. **禁止同时占用两组 8 卡服务**
   - Serial 不是 Parallel
   - model_1 的服务未停止前，禁止启动 model_2

3. **可以预创建多个容器，但服务必须串行启动**
   - 预创建容器可以并行
   - 服务启动必须串行

4. **停止服务后必须验证资源释放**
   - 检查进程（宿主机）：`ssh <NODE> "pgrep -af 'vllm serve' && exit 1 || true"` 应返回成功
   - 检查端口（宿主机）：`PORT_HEX=\$(printf '%04X' \$PORT); ssh <NODE> "ss -tlnp | grep \":\${PORT} \" || netstat -tlnp | grep \":\${PORT} \" || cat /proc/net/tcp | grep \"\$PORT_HEX\""` 应返回空

### 删除操作硬规则

**删除操作必须独立授权，不得混在其他流程中：**

1. **默认禁止 docker rm**
   - 只有用户明确说"删除/移除/rm 某个容器名"时才允许删除
   - "清理""释放资源""重启服务"默认只表示 stop/kill 服务，不表示 rm

2. **禁止批量删除旧容器**
   - 除非用户逐项确认容器名

3. **删除前必须先 stop，确认资源释放后再 rm**
   - 用户要求删除时，执行顺序：stop → 确认释放 → rm

---

## 1. 命名规范

### 容器命名格式

```
<container_prefix>-<MMDD>-<MODEL_SHORT>-<IMAGE_PREFIX>

示例：
<container_prefix>-0428-glm47int8-2540

说明：
- lzh: 固定前缀
- agent-test: 固定标识（表示这是 agent skill 测试环境）
- MMDD: 月日，如 0428
- MODEL_SHORT: 模型名简写：
  - GLM-4.7-W8A8 / GLM-4.7-Channel-INT8 → glm47int8
  - GLM-5.1-Channel-INT8 → glm51int8
  - GLM-4.7-W8A16 / GLM-4.7-Channel-FP8 → glm47fp8
  - GLM-5.1-Channel-FP8 → glm51fp8
  - GLM-4.7（未标精度，默认 bf16）→ glm47
  - GLM-5.1（未标精度，默认 bf16）→ glm51
- IMAGE_PREFIX: 镜像 tag 的前 4 位，如 2540（来自 25401bd053af）
```

### 工作路径命名格式

```
<MODEL>-<TEST_MODE>-<DATE>-<CONTAINER_NAME>/

示例：
GLM-4.7-W8A8-serial-full-20260515-<container_prefix>-0428-glm47int8-2540/

说明：
- MODEL: GLM-4.7-W8A8
- TEST_MODE: serial-full（执行模式-测试模式组合）
- DATE: 20260515
- CONTAINER_NAME: <container_prefix>-0428-glm47int8-2540
```

### 工作路径子目录结构

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

---

## 2. 执行模式定义

### Single 模式

单模型 8 卡测试，适用于单个模型验证场景。

- **GPU 分配**：HIP_VISIBLE_DEVICES=0,1,2,3,4,5,6,7
- **TP**：默认 8
- **容器**：单个容器
- **工作路径创建**：
  ```bash
  WORK_DIR="<OUTPUT_ROOT>/work_dirs/<MODEL>-<TEST_MODE>-<DATE>-<CONTAINER_NAME>/"
  mkdir -p "${WORK_DIR}/logs" "${WORK_DIR}/csvs"
  ```

### Serial 模式

多模型顺序测试，适用于同一节点上多个模型依次验证场景。

- **GPU 分配**：HIP_VISIBLE_DEVICES=0,1,2,3,4,5,6,7（所有 GPU）
- **TP**：每个模型默认 8
- **执行顺序**：模型 A 完成 → 停止服务 → 验证释放 → 模型 B 启动
- **容器策略**：每个模型使用独立容器（per_model），服务严格串行

### Parallel 模式

双 4 卡模型同时测试，适用于需要同时验证两个模型的场景。

- **GPU 分配**：
  - 模型 A：HIP_VISIBLE_DEVICES=0,1,2,3（GPU 0-3）
  - 模型 B：HIP_VISIBLE_DEVICES=4,5,6,7（GPU 4-7）
- **TP**：每个模型 4
- **容器**：每个模型创建独立容器
- **并行执行**：两个服务同时启动，两个测试同时执行

---

---

## 3. GPU 分配规则

### Parallel 模式 GPU 校验

执行前必须校验：

1. **GPU 不冲突**：两个模型的 GPU range 不能重叠
2. **总 GPU 需求**：sum(model.tp) <= node.gpu_count（8）
3. **单个模型约束**：model.tp <= 4（每组 GPU 的最大数量）

### GPU Range 定义

| 模式 | 模型 | GPU Range | TP |
|------|------|-----------|-----|
| Single | 单模型 | 0,1,2,3,4,5,6,7 | 8 |
| Serial | 模型 A | 0,1,2,3,4,5,6,7 | 8 |
| Serial | 模型 B | 0,1,2,3,4,5,6,7 | 8 |
| Parallel | 模型 A | 0,1,2,3 | 4 |
| Parallel | 模型 B | 4,5,6,7 | 4 |

---

---

## 4. Serial 模式执行流程（状态机）

```
┌─────────────────────────────────────────────────────────────────┐
│                    Serial 模式状态机                             │
└─────────────────────────────────────────────────────────────────┘

INIT
  │
  ▼
PREFLIGHT
  │ - SSH 连接验证
  │ - GPU 数量验证
  │ - Docker 可用性验证
  │ - 端口可用性验证
  ▼
CREATE_CONTAINER(model_1)
  │ - 创建容器（可预创建多个）
  │ - 挂载共享目录
  ▼
START_SERVICE(model_1)
  │ - 设置 HIP_VISIBLE_DEVICES=0-7
  │ - 启动 vLLM 服务
  ▼
WAIT_READY(model_1)
  │ - 等待服务启动
  │ - 执行健康检查
  │ - 注意：以下不是失败，必须继续等待
  │   - Loading safetensors checkpoint shards
  │   - No available shared memory broadcast block found
  │   - torch.compile takes ...
  ▼
RUN_BENCH(model_1)
  │ - 执行性能测试
  │ - 收集结果
  ▼
STOP_SERVICE(model_1)
  │ - 停止 vLLM 服务
  │ - 注意：使用 docker stop，不是 docker rm
  ▼
VERIFY_RELEASE(model_1)  ← 关键步骤
  │ - 检查进程：`pgrep -af 'vllm serve' && exit 1 || true` 应返回成功
  │ - 检查端口：`PORT_HEX=$(printf '%04X' $PORT); ss -tlnp | grep ":${PORT} " || ...` 应返回空
  │ - 确认资源完全释放后才能继续
  ▼
CREATE_CONTAINER(model_2)  ← 仅当有下一个模型时
  │ - 如果容器已存在且资源已释放，可复用
  │ - 如果容器需要重建，先确认旧容器已删除
  ▼
START_SERVICE(model_2)
  │ ... 重复上述流程 ...
  ▼
FINALIZE_REPORT
  │ - 聚合所有模型结果
  │ - 生成跨模型对比表
  │ - 返回最终报告
```

### Serial 模式正确流程示例

```bash
# 1. 创建容器（可预创建）
docker run -itd --name=<container_prefix>-0515-glm47int8-2540 ... <IMAGE> bash
docker run -itd --name=<container_prefix>-0515-glm51int8-2540 ... <IMAGE> bash

# 2. 启动 model_1 服务
docker exec -w /mnt/.claude/skills/vllm-perf-validation-single <container_prefix>-0515-glm47int8-2540 bash -ic '
  export GPU_RANGE=0,1,2,3,4,5,6,7
  export TP=8
  export PORT=9348
  nohup bash /mnt/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/run_glm47int8-server.sh > /mnt/skilltest/vllm-perf-validation-single/tmp/glm47.log 2>&1 &
'

# 3. 等待 model_1 就绪
sleep 180
curl -sS -m 20 -X POST "http://127.0.0.1:9348/v1/chat/completions" ...

# 4. 执行 model_1 测试
vllm bench serve --model /model/GLM-4.7-W8A8 --port 9348 ...

# 5. 停止 model_1 服务（关键：不是删除容器）
docker stop <container_prefix>-0515-glm47int8-2540

# 6. 验证资源释放（关键步骤，在宿主机执行）
PORT_HEX=$(printf '%04X' 9348)
ssh <NODE> "pgrep -af 'vllm serve' && exit 1 || true"  # 应返回成功
ssh <NODE> "ss -tlnp | grep ':9348 ' || netstat -tlnp | grep ':9348 ' || cat /proc/net/tcp | grep '$PORT_HEX'"  # 应返回空

# 7. 启动 model_2 服务
docker exec -w /mnt/.claude/skills/vllm-perf-validation-single <container_prefix>-0515-glm51int8-2540 bash -ic '
  export GPU_RANGE=0,1,2,3,4,5,6,7
  export TP=8
  export PORT=9350
  nohup bash /mnt/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/run_glm5.1-w8a8-server.sh > /mnt/skilltest/vllm-perf-validation-single/tmp/glm51.log 2>&1 &
'

# ... 继续等待就绪、测试、停止 ...
```

### Serial 模式错误示例（禁止）

```bash
# 错误：model_1 未停止就启动 model_2
docker exec <container_prefix>-0515-glm47int8-2540 ...  # model_1 仍在运行
docker exec <container_prefix>-0515-glm51int8-2540 ...  # 禁止同时运行

# 错误：用户未授权就删除容器
docker rm <container_prefix>-0515-glm47int8-2540  # 禁止，除非用户明确要求

# 错误：跳过 VERIFY_RELEASE 直接启动下一个
START_SERVICE(model_1)
RUN_BENCH(model_1)
START_SERVICE(model_2)  # 禁止！必须先 STOP_SERVICE 和 VERIFY_RELEASE
```

---

---

## 5. Parallel 模式执行流程

```
Step 1: 解析任务配置
        - 获取模型列表（2 个模型）
        - 校验 GPU 分配不冲突
        - 校验端口不冲突

Step 2: 前置检查
        - SSH 连接验证
        - GPU 数量验证（8 卡）
        - Docker 可用性验证

Step 3: 创建两个容器
        - 容器 A: <container_prefix>-0515-<modelA>-<IMAGE_PREFIX>
        - 容器 B: <container_prefix>-0515-<modelB>-<IMAGE_PREFIX>

Step 4: 并行启动两个 vLLM 服务
        - 容器 A: GPU_RANGE=0,1,2,3 TP=4 PORT=9348
        - 容器 B: GPU_RANGE=4,5,6,7 TP=4 PORT=9350

Step 5: 健康检查（两个服务都通过）
        - 服务 A 健康检查
        - 服务 B 健康检查

Step 6: 并行执行两个性能测试
        - 测试 A 执行
        - 测试 B 执行

Step 7: 停止服务 → 收集结果 → 聚合报告
        - 先停止两个服务
        - 再收集结果
        - 生成跨模型对比表
```

### Parallel 模式服务启动

```bash
# 服务 A 启动（容器 A 内）
docker exec <container_prefix>-0515-<modelA>-<IMAGE_PREFIX> bash -ic '
  export GPU_RANGE=0,1,2,3
  export TP=4
  export PORT=9348
  bash /mnt/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/run_<modelA>-server.sh
'

# 服务 B 启动（容器 B 内）
docker exec <container_prefix>-0515-<modelB>-<IMAGE_PREFIX> bash -ic '
  export GPU_RANGE=4,5,6,7
  export TP=4
  export PORT=9350
  bash /mnt/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/run_<modelB>-server.sh
'
```

---

---

## 6. 失败处理

### Serial 模式失败处理

- 单个模型失败：记录失败状态，继续下一个模型
- 最终报告汇总所有模型的执行状态

### Parallel 模式失败处理

- `fail_continue: true` 时：记录失败，继续其他任务
- `fail_continue: false` 时：停止所有任务，等待完成的任务结束

### 状态转换

```
PENDING → RUNNING → COMPLETED
                    ↓
                  FAILED
                    ↓
           (fail_continue? 继续/停止)
```

---

---

## 7. 结果聚合

### 聚合规则

| 最终状态 | 条件 |
|----------|------|
| PASS | 所有模型测试通过 |
| PARTIAL | 部分模型通过，部分失败或跳过 |
| FAIL | 所有模型测试失败 |

### 跨模型对比表

```csv
Model,GPU_Range,TP,Port,QPS(max),tok/s(max),TTFT(avg),TPOT(avg),Status
GLM-4.7-W8A8,0-7,8,9348,0.93,29.90,169.46ms,29.04ms,PASS
GLM-5.1-INT8,0-7,8,9350,0.71,22.73,234.99ms,37.83ms,PASS
```

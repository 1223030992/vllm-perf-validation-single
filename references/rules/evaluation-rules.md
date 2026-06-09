# 评测规则

本文件定义 vLLM 性能测试的测试模式、指标、结果判断方式和测试模板。

---

## 1. 测试模式

### full（发版完整测试）

**用途：**
- 全面评估模型在不同负载下的性能表现
- 发版前的标准性能验证

**测试组合：**
- 输入/输出对：512x512, 1024x1024, 4096x1024, 4096x4096, 16384x1024, 32768x1024, 512x4096
- 并发梯度：1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024

**脚本：** `scripts/client-scripts/run_perf_test-full.sh`

### pchit（Prefix Cache 命中率测试）

**用途：**
- 评估 Prefix Cache 对性能的影响
- 验证不同命中率下的吞吐量变化

**参数：**
- 总输入长度（token）
- 输出长度（token）
- 命中率列表：50%, 75%, 90%, 99%
- 并发列表

**脚本：** `scripts/client-scripts/run_perf_test-pchit-control.sh`

**命中率计算：**

```
命中率 ≈ prefix_len / total_input_len
例如：input_len=65536, prefix_len=32768 → 50% 命中率
```

### engin（Prefill 性能测试）

**用途：**
- 聚焦 prefill 阶段性能评估
- 测试不同输入长度对 prefill 延迟的影响

**测试组合：**
- 输入长度梯度：1024, 2048, 4096, 8192, 16384, 32768
- 输出长度：固定 64
- 并发梯度：1, 2, 4, 8, 16, 32, 64

**脚本：** `scripts/client-scripts/run_perf_test-engin.sh`

### custom（自定义参数测试）

**用途：**
- 特定场景的性能验证
- 调试和问题定位
- 支持任意组合的灵活测试需求

**参数（通过环境变量传递）：**
| 环境变量 | 说明 | 默认值 |
|----------|------|--------|
| `INPUT_LENS` | 输入长度列表（空格分隔） | `"1024"` |
| `OUTPUT_LEN` | 输出长度 | `64` |
| `CONCURRENCIES` | 并发列表（空格分隔） | `"1"` |
| `NUM_PROMPTS_MULT` | 请求数量倍率（num_prompts = concurrency × mult） | `4` |
| `REQUEST_RATE` | 请求率（可选，不设置则使用并发模式） | 空 |
| `PERCENTILES` | Percentile 列表 | `"95,99"` |

**请求数量计算：**
```bash
num_prompts = concurrency * NUM_PROMPTS_MULT
```

**脚本：** `scripts/client-scripts/run_perf_test-custom.sh`

**输出目录：**
```
/mnt/skilltest/vllm-perf-validation-single/csvs/<MODEL>/<DATE>-<IMAGE>-custom/
```

**输出文件：**
- `all.csv` - 测试结果汇总
- `commands_backup.txt` - 命令备份
- `logs/*.log` - 详细日志

**用法示例：**
```bash
# 在容器内执行
docker exec -w /mnt/skilltest/vllm-perf-validation-single <CONTAINER_NAME> bash -ic '
export IMAGE_NAME=<IMAGE>
export INPUT_LENS="1024 2048 4096 8192"
export OUTPUT_LEN=1024
export CONCURRENCIES="1 2 4 8"
export NUM_PROMPTS_MULT=4
export PERCENTILES="50,90,99"
bash /mnt/.claude/skills/vllm-perf-validation-single/scripts/client-scripts/run_perf_test-custom.sh \
  /model/GLM-4.7-W8A8 9348 8
'
```

**实际执行组合计算：**
- INPUT_LENS: 4 个值 (1024, 2048, 4096, 8192)
- CONCURRENCIES: 4 个值 (1, 2, 4, 8)
- 总组合数: 4 × 4 = 16 种

**注意：** 原始的 positional 参数方式（input_len output_len num_prompts concurrency）仍然可用，但推荐使用环境变量方式以获得更灵活的组合测试能力。

---

## 2. 自定义测试模板

当用户明确指定 engin 模式的参数时，可以直接使用 `vllm bench serve`。

### 自定义 engin 测试

```bash
ssh <NODE_IP> "docker exec -w /mnt/skilltest/vllm-perf-validation-single <CONTAINER_NAME> bash -ic '
mkdir -p /mnt/skilltest/vllm-perf-validation-single/logs

run_test() {
  local input_len=\$1
  local output_len=\$2
  local num_prompts=\$3
  local concurrency=\$4
  local label=\${input_len}-\${output_len}-c\${concurrency}

  echo \"============================================================\"
  echo \"测试: input=\$input_len output=\$output_len concurrency=\$concurrency num_prompts=\$num_prompts\"
  echo \"============================================================\"

  vllm bench serve \
    --model \"<MODEL_PATH>\" \
    --random-input-len \$input_len \
    --random-output-len \$output_len \
    --port <PORT> \
    --metric-percentiles 95,99 \
    --dataset-name random \
    --num-prompts \$num_prompts \
    --max-concurrency \$concurrency \
    --ignore-eos \
    --trust-remote-code \
    2>&1 | tee /mnt/skilltest/vllm-perf-validation-single/logs/engin-\$label.log
}

# 示例：并发 1/2/4/8，请求数为 2 倍并发
run_test 4096 64 2 1
run_test 4096 64 4 2
run_test 4096 64 8 4
run_test 4096 64 16 8
'"
```

### 自定义 pchit 测试

```bash
ssh <NODE_IP> "docker exec -w /mnt/skilltest/vllm-perf-validation-single <CONTAINER_NAME> bash -ic '
vllm bench serve \
  --model \"<MODEL_PATH>\" \
  --dataset-name random \
  --random-input-len <RANDOM_INPUT_LEN> \
  --random-output-len <OUTPUT_LEN> \
  --random-prefix-len <PREFIX_LEN> \
  --num-prompts <NUM_PROMPTS> \
  --max-concurrency <CONCURRENCY> \
  --port <PORT> \
  --metric-percentiles 95,99 \
  --ignore-eos \
  --trust-remote-code"
```

---

## 3. 核心指标

| 指标 | 说明 | 单位 | 优化方向 |
|--------|-------------|:-:|----------|
| req/s (QPS) | 每秒完成的请求数 | req/s | 越高越好 |
| tok/s | 每秒生成的输出 token 数 | tok/s | 越高越好 |
| TTFT | Time to First Token | ms | 越低越好 |
| TPOT | Time Per Output Token | ms | 越低越好 |
| ITL | Inter Token Latency | ms | 越低越好 |
| P95/P99 | 延迟百分位 | ms | 越低越好 |

---

## 4. 结果判断

### 服务异常判定

以下情况判定为服务异常：
- 服务无法启动
- API 请求失败率 > 5%
- 大量请求超时

### 性能异常判定

以下情况判定为性能异常：
- QPS 明显低于预期
- TTFT/TPOT 明显高于预期
- 高并发下性能急剧下降

---

## 5. baseline 对比

baseline 默认只读。

如果没有 baseline，应明确标记为 `baseline_missing`。

---

## 6. 评测失败分层

- `SERVICE_START_FAILED`
- `SERVICE_NOT_READY`
- `TEST_SCRIPT_FAILED`
- `BENCHMARK_TIMEOUT`
- `METRICS_PARSING_FAILED`

---

## 7. 输出要求

每个测试结果至少包含：

- test_mode
- input_len, output_len
- num_prompts, max_concurrency
- QPS, tok/s
- TTFT, TPOT, ITL
- P95, P99
- status

---

## 8. 日志严重性判断

### 以下 warning 不应直接判定失败

- NUMA balancing warning
- aiter optional warning
- lmslim optional warning
- lightop optional warning
- profiler deprecated warning
- `trust_remote_code` ignored
- `bash: cannot set terminal process group`
- `bash: no job control in this shell`
- `Triton not installed or not compatible`

### 以下内容应进入故障排查

- `Traceback`
- `ImportError`
- `ModuleNotFoundError`
- `RuntimeError`
- `cannot open shared object file`
- 服务进程退出
- 端口长期未监听
- 健康检查持续失败直到超时

**注意：** 如果当前服务进程存在且健康检查成功，不得用旧日志中的错误判定当前服务失败。

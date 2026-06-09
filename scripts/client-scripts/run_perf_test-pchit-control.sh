#!/bin/bash
#
# Prefix Cache 命中率控制性能测试脚本
#
set -o pipefail

# 原理：
#   vllm bench serve 的 --dataset-name random 支持 --random-prefix-len 参数，
#   该参数指定所有请求共享的固定前缀 token 数量。
#   KV Cache 命中率 ≈ prefix_len / total_input_len
#
# 用法：
#   ./run_perf_test-pchit-control.sh <MODEL_PATH> <PORT> <TP> [CACHE_HIT_PCT...]
#
# 环境变量（可选）：
#   WORK_DIR     - 统一工作路径根目录，如未设置则使用旧路径结构
#   TEST_MODE    - 测试模式（用于子目录），如 pchit
#   INPUT_LEN    - 总输入长度，默认 65536
#   OUTPUT_LEN   - 输出长度，默认 256
#   BATCHES      - 并发列表，默认 "1 2 4"
#   CONCURRENCY_MULTIPLIER - 并发乘数，默认 4
#   IMAGE_NAME   - 镜像名称，用于文件夹命名
#   SERVED_MODEL_ID / BENCH_MODEL_ID - 优先用于 bench --model
#   ENDPOINT     - vllm bench endpoint，默认 /v1/completions
#

MODEL_PATH=${1:?缺少参数 MODEL_PATH}
PORT=${2:?缺少参数 PORT}
TP=${3:?缺少参数 TP}
shift 3
if [[ $# -gt 0 ]]; then
    CACHE_HIT_RATES="$*"
else
    CACHE_HIT_RATES=${CACHE_HIT_RATES:-99}
fi
CACHE_HIT_RATES=$(echo "$CACHE_HIT_RATES" | tr ',' ' ')
BENCH_MODEL_ID=${BENCH_MODEL_ID:-${SERVED_MODEL_ID:-$MODEL_PATH}}
ENDPOINT=${ENDPOINT:-/v1/completions}

# 测试参数
INPUT_LEN=${INPUT_LEN:-65536}
OUTPUT_LEN=${OUTPUT_LEN:-256}
BATCHES=${BATCHES:-"1 2 4"}
BATCHES=$(echo "$BATCHES" | tr ',' ' ')
CONCURRENCY_MULTIPLIER=${CONCURRENCY_MULTIPLIER:-4}
HIGH_BATCH_THRESHOLD=${HIGH_BATCH_THRESHOLD:-128}
HIGH_BATCH_MULTIPLIER=${HIGH_BATCH_MULTIPLIER:-4}
IMAGE_NAME=${IMAGE_NAME:-unknown}
GPU_RANGE=${GPU_RANGE:-"0,1,2,3,4,5,6,7"}
TEST_MODE=${TEST_MODE:-pchit}
PCHIT_WARMUP_ONLY=${PCHIT_WARMUP_ONLY:-0}
PCHIT_TARGET_PCT=${PCHIT_TARGET_PCT:-}
PCHIT_OBSERVED_PC_HIT_PCT=${PCHIT_OBSERVED_PC_HIT_PCT:-}
PCHIT_WARMUP_RATE=${PCHIT_WARMUP_RATE:-}
PCHIT_WARMUP_ROUNDS=${PCHIT_WARMUP_ROUNDS:-}
PCHIT_WARMUP_DURATION_SECONDS=${PCHIT_WARMUP_DURATION_SECONDS:-}

model=${MODEL_NAME:-${BENCH_MODEL_ID##*/}}
date=$(date "+%Y%m%d")
time=$(date "+%H%M")

# 工作路径设置
if [[ -n "$WORK_DIR" ]]; then
    # 新模式：使用统一工作路径
    LOG_DIR="${WORK_DIR}/logs"
    CSV_DIR="${WORK_DIR}/csvs/${TEST_MODE}"
    RUN_DIR="${WORK_DIR}"
    mkdir -p "${LOG_DIR}" "${CSV_DIR}"
else
    # 旧模式：兼容现有结构
    image_tag=${IMAGE_NAME: -12}
    OUTPUT_BASE="/mnt/skilltest/vllm-perf-validation-single/csvs/${model}"
    RUN_DIR="${OUTPUT_BASE}/${date}-${image_tag}-${TEST_MODE}"
    LOG_DIR="${RUN_DIR}/logs"
    mkdir -p "${LOG_DIR}"
    CSV_DIR="${RUN_DIR}"
fi

all_log="${CSV_DIR}/all.csv"

# 保存命令备份
{
    echo "# 测试时间: $(date "+%Y-%m-%d %H:%M:%S")"
    echo "# 模型路径: ${MODEL_PATH}"
    echo "# Served model id: ${SERVED_MODEL_ID:-未设置}"
    echo "# Bench model id: ${BENCH_MODEL_ID}"
    echo "# Endpoint: ${ENDPOINT}"
    echo "# 镜像: ${IMAGE_NAME}"
    echo "# GPU 范围: ${GPU_RANGE}"
    echo "# TP: ${TP}"
    echo "# TEST_MODE: ${TEST_MODE}"
    if [[ -n "$WORK_DIR" ]]; then
    echo "# WORK_DIR: ${WORK_DIR}"
    fi
    echo ""
    echo "# 测试参数:"
    echo "#   INPUT_LEN=${INPUT_LEN}"
    echo "#   OUTPUT_LEN=${OUTPUT_LEN}"
    echo "#   CACHE_HIT_RATES=${CACHE_HIT_RATES}"
    echo "#   BATCHES=${BATCHES}"
    echo ""
    echo "# Client 测试命令:"
    echo "vllm bench serve \\"
    echo "  --model ${BENCH_MODEL_ID} \\"
    echo "  --endpoint ${ENDPOINT} \\"
    echo "  --dataset-name random \\"
    echo "  --random-input-len <RANDOM_INPUT> \\"
    echo "  --random-output-len ${OUTPUT_LEN} \\"
    echo "  --random-prefix-len <PREFIX_LEN> \\"
    echo "  --num-prompts <NUM_PROMPTS> \\"
    echo "  --port ${PORT} \\"
    echo "  --metric-percentiles 95,99 \\"
    echo "  --max-concurrency <BATCH> \\"
    echo "  --ignore-eos \\"
    echo "  --trust-remote-code"
} > "${RUN_DIR}/commands_backup.txt"

echo "cache_hit_pct,prefix_len,input,output,num_prompts,concurrency,duration_s,rps,generate_throughput_tok_s,total_throughput_tok_s,mean_ttft_ms,p95_ttft_ms,p99_ttft_ms,mean_tpot_ms,p95_tpot_ms,p99_tpot_ms,mean_itl_ms,p95_itl_ms,p99_itl_ms,QPM,prefill_throughput_tok_s_per_gpu,decode_throughput_tok_s_per_gpu,observed_pc_hit_pct,pc_hit_target_pct,warmup_rate,warmup_rounds,warmup_duration_s,status,error_reason" > "$all_log"

echo "============================================================"
echo " Prefix Cache 命中率性能测试"
echo " 模型路径: ${MODEL_PATH}"
echo " Bench 模型: ${BENCH_MODEL_ID}"
echo " Endpoint: ${ENDPOINT}"
echo " TP: ${TP}"
echo " 总输入长度: ${INPUT_LEN} tokens"
echo " 输出长度: ${OUTPUT_LEN} tokens"
echo " 测试命中率: ${CACHE_HIT_RATES[*]}%"
echo " 并发列表: ${BATCHES}"
if [[ -n "$WORK_DIR" ]]; then
echo " WORK_DIR: ${WORK_DIR}"
fi
echo "============================================================"

for cache_hit_pct in $CACHE_HIT_RATES; do
    prefix_len=$(( INPUT_LEN * cache_hit_pct / 100 ))
    echo ""
    echo ">>> 测试 KV Cache 命中率: ${cache_hit_pct}%  (prefix_len=${prefix_len}, total_input=${INPUT_LEN})"
    echo "------------------------------------------------------------"

    for batch in $BATCHES; do
        if [[ $batch -gt $HIGH_BATCH_THRESHOLD ]]; then
            num_prompts=$((batch * HIGH_BATCH_MULTIPLIER))
        else
            num_prompts=$((batch * CONCURRENCY_MULTIPLIER))
        fi

        log_file="${LOG_DIR}/${model}-tp${TP}-batch${batch}-cache${cache_hit_pct}pct-in${INPUT_LEN}-out${OUTPUT_LEN}.log"

        # random_input_len = 总输入 - prefix_len
        random_input_len=$((INPUT_LEN - prefix_len))

        vllm bench serve \
            --model "${BENCH_MODEL_ID}" \
            --endpoint "$ENDPOINT" \
            --dataset-name random \
            --random-input-len "$random_input_len" \
            --random-output-len "$OUTPUT_LEN" \
            --random-prefix-len "$prefix_len" \
            --num-prompts "$num_prompts" \
            --port "$PORT" \
            --metric-percentiles 95,99 \
            --max-concurrency "$batch" \
            --ignore-eos \
            --trust-remote-code \
            2>&1 | tee "$log_file"
        bench_rc=${PIPESTATUS[0]}

        # 提取指标
        Benchmark_duration=$(grep -a "^Benchmark duration" "$log_file" | awk '{print $4}')
        Total_input_tokens=$(grep -a "^Total input tokens" "$log_file" | awk '{print $4}')
        Total_generated_tokens=$(grep -a "^Total generated tokens" "$log_file" | awk '{print $4}')
        Output_token_throughput=$(grep -a "^Output token throughput" "$log_file" | awk '{print $5}')
        Total_Token_throughput=$(grep -ai "^Total token throughput" "$log_file" | awk '{print $5}')
        request_rate=$(grep -a "^Traffic request rate" "$log_file" | awk '{print $4}')
        qps=$(grep -a "^Request throughput" "$log_file" | awk '{print $4}')
        successful=$(grep -a "^Successful requests" "$log_file" | awk '{print $4}')
        failed=$(grep -a "^Failed requests" "$log_file" | awk '{print $4}')
        Mean_TTFT=$(grep -a "^Mean TTFT" "$log_file" | awk '{print $4}')
        Mean_TPOT=$(grep -a "^Mean TPOT" "$log_file" | awk '{print $4}')
        Median_TTFT=$(grep -a "^Median TTFT" "$log_file" | awk '{print $4}')
        Median_TPOT=$(grep -a "^Median TPOT" "$log_file" | awk '{print $4}')
        Median_ITL=$(grep -a "^Median ITL" "$log_file" | awk '{print $4}')
        P99_TTFT=$(grep -a "^P99 TTFT" "$log_file" | awk '{print $4}')
        P99_TPOT=$(grep -a "^P99 TPOT" "$log_file" | awk '{print $4}')
        P99_ITL=$(grep -a "^P99 ITL" "$log_file" | awk '{print $4}')
        P95_TTFT=$(grep -a "^P95 TTFT" "$log_file" | awk '{print $4}')
        P95_TPOT=$(grep -a "^P95 TPOT" "$log_file" | awk '{print $4}')
        P95_ITL=$(grep -a "^P95 ITL" "$log_file" | awk '{print $4}')
        Mean_ITL=$(grep -a "^Mean ITL" "$log_file" | awk '{print $4}')

        QPM=$(awk "BEGIN {print ${qps:-0} * 60}")
        prefill_throughput=$(awk "BEGIN {printf \"%.2f\", ${Total_input_tokens:-0} / ${Benchmark_duration:-1} / ${TP}}")
        decode_throughput=$(awk "BEGIN {printf \"%.2f\", ${Total_generated_tokens:-0} / ${Benchmark_duration:-1} / ${TP}}")

        # 判断状态
        if [[ "$bench_rc" != "0" ]]; then
            status="FAIL"
            error_reason="bench_exit_nonzero"
        elif [[ -n "$successful" && "$successful" == "0" && -n "$failed" && "$failed" != "0" ]]; then
            status="FAIL"
            error_reason="all_requests_failed_${failed}"
        elif [[ -n "$failed" && "$failed" != "0" ]]; then
            status="PARTIAL"
            error_reason="failed_requests_${failed}"
        elif [[ -n "$qps" && "$qps" != "0" ]]; then
            status="PASS"
            error_reason=""
        else
            status="FAIL"
            error_reason="invalid_metrics"
        fi

        echo "${cache_hit_pct},${prefix_len},${INPUT_LEN},${OUTPUT_LEN},${num_prompts},${batch},${Benchmark_duration},${qps},${Output_token_throughput},${Total_Token_throughput},${Mean_TTFT},${P95_TTFT},${P99_TTFT},${Mean_TPOT},${P95_TPOT},${P99_TPOT},${Mean_ITL},${P95_ITL},${P99_ITL},${QPM},${prefill_throughput},${decode_throughput},${PCHIT_OBSERVED_PC_HIT_PCT},${PCHIT_TARGET_PCT},${PCHIT_WARMUP_RATE},${PCHIT_WARMUP_ROUNDS},${PCHIT_WARMUP_DURATION_SECONDS},${status},${error_reason}" >> "$all_log"

        echo "  ✓ cache_hit=${cache_hit_pct}% batch=${batch} 完成"
    done
done

# 追加实际执行组合摘要
{
    echo ""
    echo "# 实际执行组合（汇总）:"
    for cache_hit_pct in $CACHE_HIT_RATES; do
        prefix_len=$(( INPUT_LEN * cache_hit_pct / 100 ))
        first_batch=""
        last_batch=""
        for batch in $BATCHES; do
            [[ -z $first_batch ]] && first_batch=$batch
            last_batch=$batch
        done
        echo "#   cache_hit=${cache_hit_pct}% (prefix_len=${prefix_len}): batch ${first_batch}-${last_batch}"
    done
} >> "${RUN_DIR}/commands_backup.txt"

echo ""
echo "============================================================"
echo " 测试完成！结果汇总："
echo "============================================================"
cat "$all_log"
echo ""
echo "完整结果已保存到: ${all_log}"
echo "命令备份: ${RUN_DIR}/commands_backup.txt"

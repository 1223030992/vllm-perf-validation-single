#!/bin/bash
#
# Prefill 性能测试脚本（Engineer 模式）
#
set -o pipefail

# 用法：
#   ./run_perf_test-engin.sh <MODEL_PATH> <PORT> <TP>
#
# 环境变量（可选）：
#   WORK_DIR     - 统一工作路径根目录，如未设置则使用旧路径结构
#   TEST_MODE    - 测试模式（用于子目录），如 engin
#   OUTPUT_LEN   - 输出长度，默认 64
#   INPUT_LENS   - 输入长度列表，默认 "1024 2048 4096 8192 16384 32768"
#   BATCHES      - 并发列表，默认 "1 2 4 8 16 32 64"
#   IMAGE_NAME   - 镜像名称，用于文件夹命名
#   SERVED_MODEL_ID / BENCH_MODEL_ID - 优先用于 bench --model
#   ENDPOINT     - vllm bench endpoint，默认 /v1/completions
#

MODEL_PATH=${1:?缺少参数 MODEL_PATH}
PORT=${2:?缺少参数 PORT}
TP=${3:?缺少参数 TP}
BENCH_MODEL_ID=${BENCH_MODEL_ID:-${SERVED_MODEL_ID:-$MODEL_PATH}}
ENDPOINT=${ENDPOINT:-/v1/completions}

# 测试参数
OUTPUT_LEN=${OUTPUT_LEN:-64}
INPUT_LENS=${INPUT_LENS:-"1024 2048 4096 8192 16384 32768"}
BATCHES=${BATCHES:-"1 2 4 8 16 32 64"}
IMAGE_NAME=${IMAGE_NAME:-unknown}
GPU_RANGE=${GPU_RANGE:-"0,1,2,3,4,5,6,7"}
TEST_MODE=${TEST_MODE:-engin}

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
    echo "#   OUTPUT_LEN=${OUTPUT_LEN}"
    echo "#   INPUT_LENS=${INPUT_LENS}"
    echo "#   BATCHES=${BATCHES}"
    echo ""
    echo "# Client 测试命令:"
    echo "vllm bench serve \\"
    echo "  --model ${BENCH_MODEL_ID} \\"
    echo "  --endpoint ${ENDPOINT} \\"
    echo "  --port ${PORT} \\"
    echo "  --dataset-name random \\"
    echo "  --random-input-len <INPUT> \\"
    echo "  --random-output-len ${OUTPUT_LEN} \\"
    echo "  --metric-percentiles 50,90,99 \\"
    echo "  --num-prompts <BATCH> \\"
    echo "  --max-concurrency <BATCH> \\"
    echo "  --ignore-eos \\"
    echo "  --trust-remote-code"
} > "${RUN_DIR}/commands_backup.txt"

echo "input,output,request_rate,num_prompts,concurrency,duration_s,rps,generate_throughput_tok_s,total_throughput_tok_s,mean_ttft_ms,median_ttft_ms,p90_ttft_ms,p99_ttft_ms,mean_tpot_ms,median_tpot_ms,p90_tpot_ms,p99_tpot_ms,mean_itl_ms,p50_itl_ms,p90_itl_ms,p99_itl_ms,status,error_reason" > "${all_log}"

echo "============================================================"
echo " Prefill 性能测试 (Engineer Mode)"
echo " 模型路径: ${MODEL_PATH}"
echo " Bench 模型: ${BENCH_MODEL_ID}"
echo " Endpoint: ${ENDPOINT}"
echo " TP: ${TP}"
echo " 输出长度: ${OUTPUT_LEN}"
echo " 输入长度: ${INPUT_LENS}"
echo " 并发: ${BATCHES}"
if [[ -n "$WORK_DIR" ]]; then
echo " WORK_DIR: ${WORK_DIR}"
fi
echo "============================================================"

for prompt_tokens in $INPUT_LENS; do
    echo ""
    echo ">>> 测试 input=${prompt_tokens}, output=${OUTPUT_LEN}"
    echo "------------------------------------------------------------"

    for batch in $BATCHES; do
        logfile="${LOG_DIR}/${model}-tp${TP}-c${batch}-in${prompt_tokens}-out${OUTPUT_LEN}.log"

        vllm bench serve \
            --model "${BENCH_MODEL_ID}" \
            --endpoint "$ENDPOINT" \
            --port "${PORT}" \
            --dataset-name random \
            --random-input-len "${prompt_tokens}" \
            --random-output-len "${OUTPUT_LEN}" \
            --metric-percentiles 50,90,99 \
            --num-prompts "${batch}" \
            --max-concurrency "${batch}" \
            --ignore-eos \
            --trust-remote-code \
            2>&1 | tee "${logfile}"
        bench_rc=${PIPESTATUS[0]}

        # 提取指标
        Benchmark_duration=$(grep -a "^Benchmark duration" "${logfile}" | awk '{print $4}')
        Output_token_throughput=$(grep -a "^Output token throughput" "${logfile}" | awk '{print $5}')
        Total_Token_throughput=$(grep -a "^Total token throughput" "${logfile}" | awk '{print $5}')
        request_rate=$(grep -a "^Traffic request rate" "${logfile}" | awk '{print $4}')
        qps=$(grep -a "^Request throughput" "${logfile}" | awk '{print $4}')
        successful=$(grep -a "^Successful requests" "${logfile}" | awk '{print $4}')
        failed=$(grep -a "^Failed requests" "${logfile}" | awk '{print $4}')

        Mean_TTFT=$(grep -a "^Mean TTFT" "${logfile}" | awk '{print $4}')
        P50_TTFT=$(grep -a "^P50 TTFT" "${logfile}" | awk '{print $4}')
        P90_TTFT=$(grep -a "^P90 TTFT" "${logfile}" | awk '{print $4}')
        P99_TTFT=$(grep -a "^P99 TTFT" "${logfile}" | awk '{print $4}')

        Mean_TPOT=$(grep -a "^Mean TPOT" "${logfile}" | awk '{print $4}')
        P50_TPOT=$(grep -a "^P50 TPOT" "${logfile}" | awk '{print $4}')
        P90_TPOT=$(grep -a "^P90 TPOT" "${logfile}" | awk '{print $4}')
        P99_TPOT=$(grep -a "^P99 TPOT" "${logfile}" | awk '{print $4}')

        Mean_ITL=$(grep -a "^Mean ITL" "${logfile}" | awk '{print $4}')
        P50_ITL=$(grep -a "^P50 ITL" "${logfile}" | awk '{print $4}')
        P90_ITL=$(grep -a "^P90 ITL" "${logfile}" | awk '{print $4}')
        P99_ITL=$(grep -a "^P99 ITL" "${logfile}" | awk '{print $4}')

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

        echo "${prompt_tokens},${OUTPUT_LEN},${request_rate},${batch},${batch},${Benchmark_duration},${qps},${Output_token_throughput},${Total_Token_throughput},${Mean_TTFT},${P50_TTFT},${P90_TTFT},${P99_TTFT},${Mean_TPOT},${P50_TPOT},${P90_TPOT},${P99_TPOT},${Mean_ITL},${P50_ITL},${P90_ITL},${P99_ITL},${status},${error_reason}" >> "${all_log}"

        echo "  ✓ batch=${batch} 完成"
    done
done

# 追加实际执行组合摘要
{
    echo ""
    echo "# 实际执行组合（汇总）:"
    for prompt_tokens in $INPUT_LENS; do
        first_batch=""
        last_batch=""
        for batch in $BATCHES; do
            [[ -z $first_batch ]] && first_batch=$batch
            last_batch=$batch
        done
        echo "#   (${prompt_tokens}, ${OUTPUT_LEN}): batch ${first_batch}-${last_batch}"
    done
} >> "${RUN_DIR}/commands_backup.txt"

echo ""
echo "============================================================"
echo " 测试完成！结果汇总："
echo "============================================================"
cat "${all_log}"
echo ""
echo "完整结果已保存到: ${all_log}"
echo "命令备份: ${RUN_DIR}/commands_backup.txt"

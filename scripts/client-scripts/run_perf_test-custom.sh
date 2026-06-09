#!/bin/bash
#
# 灵活参数性能测试脚本（Custom 模式）
#
set -o pipefail

# 用法：
#   ./run_perf_test-custom.sh <MODEL_PATH> <PORT> <TP>
#
# 环境变量（可选）：
#   WORK_DIR          - 统一工作路径根目录，如未设置则使用旧路径结构
#   TEST_MODE        - 测试模式（用于子目录），如 custom
#   INPUT_LENS        - 输入长度列表（空格分隔），默认 "1024"
#   OUTPUT_LEN        - 输出长度，默认 64
#   CONCURRENCIES     - 并发列表（空格分隔），默认 "1"
#   NUM_PROMPTS_MULT - 请求数量倍率（num_prompts = concurrency × mult），默认 4
#   REQUEST_RATE     - 请求率（可选，不设置则使用并发模式）
#   PERCENTILES      - Percentile 列表，默认 "95,99"
#   IMAGE_NAME       - 镜像名称，用于文件夹命名
#   SERVED_MODEL_ID  - /v1/models 返回的模型 ID，优先用于 bench --model
#   BENCH_MODEL_ID   - 显式覆盖 bench --model
#   ENDPOINT         - vllm bench endpoint，默认 /v1/completions
#

MODEL_PATH=${1:?缺少参数 MODEL_PATH}
PORT=${2:?缺少参数 PORT}
TP=${3:?缺少参数 TP}
BENCH_MODEL_ID=${BENCH_MODEL_ID:-${SERVED_MODEL_ID:-$MODEL_PATH}}
ENDPOINT=${ENDPOINT:-/v1/completions}

# 测试参数
INPUT_LENS=${INPUT_LENS:-"1024"}
OUTPUT_LEN=${OUTPUT_LEN:-64}
CONCURRENCIES=${CONCURRENCIES:-"1"}
NUM_PROMPTS_MULT=${NUM_PROMPTS_MULT:-4}
REQUEST_RATE=${REQUEST_RATE:-""}
PERCENTILES=${PERCENTILES:-"95,99"}
IMAGE_NAME=${IMAGE_NAME:-unknown}
GPU_RANGE=${GPU_RANGE:-"0,1,2,3,4,5,6,7"}
TEST_MODE=${TEST_MODE:-custom}

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
    echo "#   INPUT_LENS=${INPUT_LENS}"
    echo "#   OUTPUT_LEN=${OUTPUT_LEN}"
    echo "#   CONCURRENCIES=${CONCURRENCIES}"
    echo "#   NUM_PROMPTS_MULT=${NUM_PROMPTS_MULT}"
    echo "#   REQUEST_RATE=${REQUEST_RATE:-未设置}"
    echo "#   PERCENTILES=${PERCENTILES}"
    echo ""
    echo "# Client 测试命令模板:"
    echo "vllm bench serve \\"
    echo "  --model ${BENCH_MODEL_ID} \\"
    echo "  --port ${PORT} \\"
    echo "  --endpoint ${ENDPOINT} \\"
    echo "  --dataset-name random \\"
    echo "  --random-input-len <INPUT> \\"
    echo "  --random-output-len ${OUTPUT_LEN} \\"
    echo "  --num-prompts <NUM_PROMPTS> \\"
    echo "  --max-concurrency <CONCURRENCY> \\"
    if [[ -n "$REQUEST_RATE" ]]; then
    echo "  --request-rate ${REQUEST_RATE} \\"
    fi
    echo "  --metric-percentiles ${PERCENTILES} \\"
    echo "  --ignore-eos \\"
    echo "  --trust-remote-code"
} > "${RUN_DIR}/commands_backup.txt"

# CSV 文件头
echo "input,output,num_prompts,concurrency,request_rate,duration_s,rps,generate_throughput_tok_s,total_throughput_tok_s,mean_ttft,p50_ttft,p90_ttft,p99_ttft,mean_tpot,p50_tpot,p90_tpot,p99_tpot,mean_itl,p50_itl,p90_itl,p99_itl,status,error_reason" > "$all_log"

echo "============================================================"
echo " Custom 性能测试"
echo " 模型路径: ${MODEL_PATH}"
echo " Bench 模型: ${BENCH_MODEL_ID}"
echo " Endpoint: ${ENDPOINT}"
echo " TP: ${TP}"
echo " 端口: ${PORT}"
echo " 输入长度: ${INPUT_LENS}"
echo " 输出长度: ${OUTPUT_LEN}"
echo " 并发列表: ${CONCURRENCIES}"
echo " 请求倍率: ${NUM_PROMPTS_MULT}"
echo " Percentiles: ${PERCENTILES}"
echo " 请求率: ${REQUEST_RATE:-未设置}"
if [[ -n "$WORK_DIR" ]]; then
echo " WORK_DIR: ${WORK_DIR}"
fi
echo "============================================================"

# 记录实际执行组合
exec_summary=""

# 三层循环：INPUT_LENS → CONCURRENCIES
for input_len in $INPUT_LENS; do
    for concurrency in $CONCURRENCIES; do
        num_prompts=$((concurrency * NUM_PROMPTS_MULT))

        echo ""
        echo ">>> 测试 input=${input_len}, output=${OUTPUT_LEN}, concurrency=${concurrency}, num_prompts=${num_prompts}"
        echo "------------------------------------------------------------"

        log_file="${LOG_DIR}/${model}-in${input_len}-out${OUTPUT_LEN}-c${concurrency}-n${num_prompts}.log"

        cmd=(
            vllm bench serve
            --model "$BENCH_MODEL_ID"
            --port "$PORT"
            --endpoint "$ENDPOINT"
            --dataset-name random
            --random-input-len "$input_len"
            --random-output-len "$OUTPUT_LEN"
            --num-prompts "$num_prompts"
            --max-concurrency "$concurrency"
            --metric-percentiles "$PERCENTILES"
            --ignore-eos
            --trust-remote-code
        )

        if [[ -n "$REQUEST_RATE" ]]; then
            cmd+=(--request-rate "$REQUEST_RATE")
        fi

        "${cmd[@]}" 2>&1 | tee "$log_file"
        bench_rc=${PIPESTATUS[0]}

        # 提取指标
        Benchmark_duration=$(grep -a "^Benchmark duration" "$log_file" | awk '{print $4}')
        request_rate=$(grep -a "^Traffic request rate" "$log_file" | awk '{print $4}')
        qps=$(grep -a "^Request throughput" "$log_file" | awk '{print $4}')
        Output_token_throughput=$(grep -a "^Output token throughput" "$log_file" | awk '{print $5}')
        Total_Token_throughput=$(grep -ai "^Total token throughput" "$log_file" | awk '{print $5}')
        successful=$(grep -a "^Successful requests" "$log_file" | awk '{print $4}')
        failed=$(grep -a "^Failed requests" "$log_file" | awk '{print $4}')

        Mean_TTFT=$(grep -a "^Mean TTFT" "$log_file" | awk '{print $4}')
        P50_TTFT=$(grep -a "^P50 TTFT" "$log_file" | awk '{print $4}')
        P90_TTFT=$(grep -a "^P90 TTFT" "$log_file" | awk '{print $4}')
        P99_TTFT=$(grep -a "^P99 TTFT" "$log_file" | awk '{print $4}')

        Mean_TPOT=$(grep -a "^Mean TPOT" "$log_file" | awk '{print $4}')
        P50_TPOT=$(grep -a "^P50 TPOT" "$log_file" | awk '{print $4}')
        P90_TPOT=$(grep -a "^P90 TPOT" "$log_file" | awk '{print $4}')
        P99_TPOT=$(grep -a "^P99 TPOT" "$log_file" | awk '{print $4}')

        Mean_ITL=$(grep -a "^Mean ITL" "$log_file" | awk '{print $4}')
        P50_ITL=$(grep -a "^P50 ITL" "$log_file" | awk '{print $4}')
        P90_ITL=$(grep -a "^P90 ITL" "$log_file" | awk '{print $4}')
        P99_ITL=$(grep -a "^P99 ITL" "$log_file" | awk '{print $4}')

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

        echo "${input_len},${OUTPUT_LEN},${num_prompts},${concurrency},${request_rate:-},${Benchmark_duration},${qps},${Output_token_throughput},${Total_Token_throughput},${Mean_TTFT},${P50_TTFT},${P90_TTFT},${P99_TTFT},${Mean_TPOT},${P50_TPOT},${P90_TPOT},${P99_TPOT},${Mean_ITL},${P50_ITL},${P90_ITL},${P99_ITL},${status},${error_reason}" >> "$all_log"

        # 记录执行摘要
        exec_summary="${exec_summary}
#   (${input_len}, ${OUTPUT_LEN}): c${concurrency}-n${num_prompts}"

        echo "  ✓ 完成"
    done
done

# 追加实际执行组合摘要
{
    echo ""
    echo "# 实际执行组合（汇总）:"
    echo "$exec_summary"
} >> "${RUN_DIR}/commands_backup.txt"

echo ""
echo "============================================================"
echo " 测试完成！结果汇总："
echo "============================================================"
cat "$all_log"
echo ""
echo "结果已保存到: ${all_log}"
echo "命令备份: ${RUN_DIR}/commands_backup.txt"

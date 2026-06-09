#!/bin/bash
#
# 发版完整性能测试脚本
#
set -o pipefail

# 用法：
#   ./run_perf_test-full.sh <MODEL_PATH> <PORT> <TP>
#
# 环境变量（可选）：
#   WORK_DIR     - 统一工作路径根目录，如未设置则使用旧路径结构
#   TEST_MODE    - 测试模式（用于子目录），如 full
#   PAIRS        - 输入输出对，格式："input1 output1 max_batch1 input2 output2 max_batch2 ..."
#   BATCH_SEQ    - 并发梯度，格式："1 2 4 8 16 ..."
#   IMAGE_NAME   - 镜像名称，用于文件夹命名
#   SERVED_MODEL_ID / BENCH_MODEL_ID - 优先用于 bench --model
#   ENDPOINT     - vllm bench endpoint，默认 /v1/completions
#
# 输出目录（WORK_DIR 模式）：
#   WORK_DIR/logs/                    # 日志
#   WORK_DIR/csvs/<TEST_MODE>/        # CSV 结果
#   WORK_DIR/commands_backup.txt       # 命令备份
#

MODEL_PATH=${1:?缺少参数 MODEL_PATH}
PORT=${2:?缺少参数 PORT}
TP=${3:?缺少参数 TP}
BENCH_MODEL_ID=${BENCH_MODEL_ID:-${SERVED_MODEL_ID:-$MODEL_PATH}}
ENDPOINT=${ENDPOINT:-/v1/completions}

# 测试参数
PAIRS=${PAIRS:-"512 512 128 1024 1024 64 4096 1024 64 4096 4096 64 16384 1024 32 32768 1024 16 512 4096 128"}
BATCH_SEQ=${BATCH_SEQ:-"1 2 4 8 16 32 64 128 256 512 1024"}
IMAGE_NAME=${IMAGE_NAME:-unknown}
GPU_RANGE=${GPU_RANGE:-"0,1,2,3,4,5,6,7"}
TEST_MODE=${TEST_MODE:-full}

model=${MODEL_NAME:-${BENCH_MODEL_ID##*/}}
date=$(date "+%Y%m%d")
time=${TIME:-$(date "+%H%M")}

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
    RUN_DIR="${OUTPUT_BASE}/${date}-${image_tag}-full"
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
    echo "#   PAIRS=${PAIRS}"
    echo "#   BATCH_SEQ=${BATCH_SEQ}"
    echo ""
    echo "# Server 启动命令（如需要）:"
    echo "export GPU_RANGE=${GPU_RANGE}"
    echo "export TP=${TP}"
    echo "export MODEL_PATH=${MODEL_PATH}"
    echo "export PORT=${PORT}"
    echo "export WORK_DIR=${WORK_DIR}"
    echo "export LOG_DIR=${LOG_DIR}"
    echo "bash /mnt/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/run_<MODEL>-server.sh"
    echo ""
    echo "# Client 测试命令:"
    echo "vllm bench serve \\"
    echo "  --model ${BENCH_MODEL_ID} \\"
    echo "  --endpoint ${ENDPOINT} \\"
    echo "  --port ${PORT} \\"
    echo "  --random-input-len <INPUT> \\"
    echo "  --random-output-len <OUTPUT> \\"
    echo "  --num-prompts <BATCH> \\"
    echo "  --max-concurrency <BATCH> \\"
    echo "  --dataset-name random \\"
    echo "  --metric-percentiles 95,99 \\"
    echo "  --ignore-eos \\"
    echo "  --trust-remote-code"
} > "${RUN_DIR}/commands_backup.txt"

echo "input,output,num_prompts,concurrency,duration_s,rps,generate_throughput_tok_s,total_throughput_tok_s,mean_ttft_ms,p95_ttft_ms,p99_ttft_ms,mean_tpot_ms,p95_tpot_ms,p99_tpot_ms,mean_itl_ms,p95_itl_ms,p99_itl_ms,status,error_reason" > "$all_log"

echo "============================================================"
echo " 发版完整性能测试"
echo " 模型路径: ${MODEL_PATH}"
echo " Bench 模型: ${BENCH_MODEL_ID}"
echo " Endpoint: ${ENDPOINT}"
echo " TP: ${TP}"
echo " 端口: ${PORT}"
echo " 时间: ${date}-${time}"
if [[ -n "$WORK_DIR" ]]; then
echo " WORK_DIR: ${WORK_DIR}"
fi
echo "============================================================"

# 将 PAIRS 字符串转换为数组
read -ra PAIRS_ARRAY <<< "$PAIRS"

for ((i=0; i<${#PAIRS_ARRAY[@]}; i+=3)); do
    prompt_tokens=${PAIRS_ARRAY[$i]}
    completion_tokens=${PAIRS_ARRAY[$((i+1))]}
    max_bs=${PAIRS_ARRAY[$((i+2))]}

    echo ""
    echo ">>> 测试 input=${prompt_tokens}, output=${completion_tokens}, max_batch=${max_bs}"
    echo "------------------------------------------------------------"

    for batch in $BATCH_SEQ; do
        if [[ $batch -gt $max_bs ]]; then
            break
        fi

        log_file="${LOG_DIR}/${model}-tp${TP}-batch${batch}-in${prompt_tokens}-out${completion_tokens}.log"

        vllm bench serve \
            --model "${BENCH_MODEL_ID}" \
            --endpoint "$ENDPOINT" \
            --random-input-len "$prompt_tokens" \
            --random-output-len "$completion_tokens" \
            --port "$PORT" \
            --metric-percentiles 95,99 \
            --dataset-name random \
            --num-prompts "$batch" \
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

echo "${prompt_tokens},${completion_tokens},${batch},${batch},${Benchmark_duration},${qps},${Output_token_throughput},${Total_Token_throughput},${Mean_TTFT},${P95_TTFT},${P99_TTFT},${Mean_TPOT},${P95_TPOT},${P99_TPOT},${Mean_ITL},${P95_ITL},${P99_ITL},${status},${error_reason}" >> "$all_log"

        echo "  ✓ batch=${batch} 完成"
    done
done

# 追加实际执行组合摘要
{
    echo ""
    echo "# 实际执行组合（汇总）:"
    read -ra PAIRS_ARRAY <<< "$PAIRS"
    for ((i=0; i<${#PAIRS_ARRAY[@]}; i+=3)); do
        prompt_tokens=${PAIRS_ARRAY[$i]}
        completion_tokens=${PAIRS_ARRAY[$((i+1))]}
        max_bs=${PAIRS_ARRAY[$((i+2))]}
        # 计算该 input/output 对实际执行的 batch 范围
        first_batch=""
        last_batch=""
        for batch in $BATCH_SEQ; do
            if [[ $batch -le $max_bs ]]; then
                [[ -z $first_batch ]] && first_batch=$batch
                last_batch=$batch
            else
                break
            fi
        done
        if [[ -n $first_batch ]]; then
            echo "#   (${prompt_tokens}, ${completion_tokens}): batch ${first_batch}-${last_batch}"
        fi
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

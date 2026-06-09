#!/bin/bash
#
# add-model.sh - vLLM 性能验证 Skill 模型扩展校验器
#
# 用法:
#   ./add-model.sh --model-name "New-Model-INT8" --server-script ./my-server.sh --precision int8 --tp 8 --port 9360
#
# 功能:
#   1. 校验启动脚本规范性（语法、参数化）
#   2. 规范化脚本并注册到 Skill
#   3. 生成模型 Profile 和 task.yaml 模板
#   4. 更新 MODEL_SHORT 映射表
#

set -euo pipefail

# ============================================================
# 颜色定义
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================
# 全局变量
# ============================================================
MODEL_NAME=""
MODEL_SHORT=""
SERVER_SCRIPT=""
PRECISION=""
TP=""
PORT=""
MODEL_PATH=""
MODEL_SHORT_OVERRIDE=""
YES_FLAG=false
OVERWRITE_FLAG=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROFILES_DIR="${SKILL_ROOT}/references/profiles"
CONVENTIONS_FILE="${SKILL_ROOT}/references/conventions.md"
EXAMPLES_DIR="${SKILL_ROOT}/references/examples"

# New model onboarding is now handled by the generic local-only registrar.
# Keep this legacy script for existing callers, but delegate modern flags to
# scripts/ops/register_model.sh so Qwen/DeepSeek/GLM-5 naming rules stay in one place.
for arg in "$@"; do
    case "$arg" in
        --host-model-path|--container-model-path|--dry-run)
            exec bash "${SKILL_ROOT}/scripts/ops/register_model.sh" "$@"
            ;;
    esac
done

# 校验结果
declare -a VALIDATION_ERRORS=()
declare -a VALIDATION_WARNINGS=()
declare -a VALIDATION_OKS=()

# 提取的 vLLM 参数
EXTRACTED_MAX_MODEL_LEN=""
EXTRACTED_GPU_MEM_UTIL=""
EXTRACTED_QUANTIZATION=""
EXTRACTED_DTYPE=""
EXTRACTED_MAX_NUM_SEQS=""
EXTRACTED_MAX_NUM_BATCHED_TOKENS=""
declare -a EXTRACTED_ENV_VARS=()

# ============================================================
# 帮助信息
# ============================================================
show_help() {
    cat << EOF
用法: $(basename "$0") --model-name <名称> --server-script <脚本> [选项]

必需参数:
  --model-name <名称>      模型显示名称，如 New-Model-INT8
  --server-script <路径>   服务启动脚本路径

可选参数:
  --precision <类型>       精度类型: int8, fp8, bf16 (默认: 从名称推导)
  --tp <数量>              Tensor Parallel 大小 (默认: 8)
  --port <端口>            服务端口 (默认: 9348)
  --model-path <路径>      模型路径 (默认: /model/<MODEL_NAME>)
  --model-short <简称>     手动指定 MODEL_SHORT（当自动推导失败时使用）
  --yes                    自动确认所有交互提示（非交互环境使用）
  --overwrite              允许覆盖已存在的生成文件，必须与 --yes 一起使用

示例:
  $(basename "$0") --model-name "New-Model-INT8" --server-script ./my-server.sh --precision int8 --tp 8 --port 9360
  $(basename "$0") --model-name "GLM-5.1-INT8" --server-script ./glm51.sh --precision int8
  $(basename "$0") --model-name "Qwen-2.5" --server-script ./qwen.sh --model-short qwen25 --yes

EOF
}

# ============================================================
# 参数解析
# ============================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --model-name)
                MODEL_NAME="$2"; shift 2 ;;
            --server-script)
                SERVER_SCRIPT="$2"; shift 2 ;;
            --precision)
                PRECISION="$2"; shift 2 ;;
            --tp)
                TP="$2"; shift 2 ;;
            --port)
                PORT="$2"; shift 2 ;;
            --model-path)
                MODEL_PATH="$2"; shift 2 ;;
            --model-short)
                MODEL_SHORT_OVERRIDE="$2"; shift 2 ;;
            --yes)
                YES_FLAG=true; shift ;;
            --overwrite)
                OVERWRITE_FLAG=true; shift ;;
            --help)
                show_help; exit 0 ;;
            *)
                log_error "未知参数: $1"; show_help; exit 1 ;;
        esac
    done

    # 校验必需参数
    if [[ -z "$MODEL_NAME" ]]; then
        log_error "--model-name 是必需的"
        exit 1
    fi
    if [[ -z "$SERVER_SCRIPT" ]]; then
        log_error "--server-script 是必需的"
        exit 1
    fi

    # 设置默认值
    TP="${TP:-8}"
    PORT="${PORT:-9348}"

    # 推导或使用指定的 MODEL_SHORT
    if [[ -n "$MODEL_SHORT_OVERRIDE" ]]; then
        MODEL_SHORT="$MODEL_SHORT_OVERRIDE"
    else
        MODEL_SHORT=$(derive_model_short "$MODEL_NAME")
        if [[ -z "$MODEL_SHORT" ]]; then
            log_error "无法推导 MODEL_SHORT：只支持 GLM-4.7* / GLM-5.1* 模型"
            log_error "或使用 --model-short 手动指定"
            exit 1
        fi
    fi

    log_info "模型名称: ${MODEL_NAME}"
    log_info "模型简称: ${MODEL_SHORT}"
    log_info "精度: ${PRECISION:-<自动推导>}"
    log_info "TP: ${TP}"
    log_info "端口: ${PORT}"
}

# ============================================================
# 推导 MODEL_SHORT
# ============================================================
derive_model_short() {
    local name="$1"
    local short=""

    # 移除路径
    name="${name##*/}"

    # 精度识别
    case "$name" in
        *W8A8*|*INT8*|*Channel-INT8*)
            short="int8" ;;
        *W8A16*|*FP8*|*Channel-FP8*)
            short="fp8" ;;
        *)
            short="" ;;
    esac

    # 提取 GLM-4.7 / GLM-5.1
    if [[ "$name" =~ GLM-4\.7 ]]; then
        echo "glm47${short}"
    elif [[ "$name" =~ GLM-5\.1 ]]; then
        echo "glm51${short}"
    else
        echo ""
    fi
}

# ============================================================
# 阶段 1: 脚本校验
# ============================================================

# 1.1 语法检查
validate_script_syntax() {
    log_info "检查脚本语法..."
    if bash -n "$SERVER_SCRIPT" 2>/dev/null; then
        VALIDATION_OKS+=("语法检查通过")
        return 0
    else
        VALIDATION_ERRORS+=("语法检查失败: $SERVER_SCRIPT")
        return 1
    fi
}

# 1.2 可执行权限检查
validate_executable() {
    log_info "检查可执行权限..."
    if [[ -x "$SERVER_SCRIPT" ]]; then
        VALIDATION_OKS+=("可执行权限")
        return 0
    else
        VALIDATION_WARNINGS+=("无可执行权限，将自动添加")
        return 0
    fi
}

# 1.3 参数化检查
validate_parameterization() {
    log_info "检查参数化..."

    local content=$(cat "$SERVER_SCRIPT")

    # 检查 GPU_RANGE / HIP_VISIBLE_DEVICES
    if grep -q 'HIP_VISIBLE_DEVICES=\${GPU_RANGE' <<< "$content" || \
       grep -q 'HIP_VISIBLE_DEVICES=\${GPU_RANGE:-' <<< "$content"; then
        VALIDATION_OKS+=("GPU_RANGE 参数化")
    elif grep -q 'HIP_VISIBLE_DEVICES=0,1,2,3' <<< "$content" || \
         grep -q 'HIP_VISIBLE_DEVICES=0,1,2,3,4,5,6,7' <<< "$content"; then
        VALIDATION_ERRORS+=("GPU_RANGE 硬编码，建议改为 \${GPU_RANGE:-0,1,2,3,4,5,6,7}")
    else
        VALIDATION_WARNINGS+=("未检测到 HIP_VISIBLE_DEVICES 参数化")
    fi

    # 检查 TP / TP_SIZE
    if grep -q '\${TP' <<< "$content" || \
       grep -q '\${TP_SIZE' <<< "$content" || \
       grep -q '-tp \${' <<< "$content"; then
        VALIDATION_OKS+=("TP 参数化")
    elif grep -q -- '-tp 8' <<< "$content" || \
         grep -q -- '-tp 4' <<< "$content"; then
        VALIDATION_WARNINGS+=("TP 硬编码，建议改为 \${TP:-8}")
    fi

    # 检查 MODEL_PATH
    if grep -q 'MODEL_PATH=\${' <<< "$content"; then
        VALIDATION_OKS+=("MODEL_PATH 参数化")
    elif grep -q 'vllm serve "/model/' <<< "$content"; then
        VALIDATION_ERRORS+=("MODEL_PATH 硬编码，建议改为 \${MODEL_PATH}")
    fi

    # 检查 PORT
    if grep -q 'PORT=\${' <<< "$content" || \
       grep -q -- '--port \${' <<< "$content"; then
        VALIDATION_OKS+=("PORT 参数化")
    elif grep -q -- '--port 934' <<< "$content" || \
         grep -q -- '--port 935' <<< "$content"; then
        VALIDATION_WARNINGS+=("PORT 硬编码，建议改为 \${PORT:-9348}")
    fi

    # 检查 LOG_DIR
    if grep -q 'LOG_DIR=\${' <<< "$content"; then
        VALIDATION_OKS+=("LOG_DIR 参数化")
    fi
}

# 1.4 提取 vLLM 参数
extract_vllm_params() {
    log_info "提取 vLLM 参数..."

    local content=$(cat "$SERVER_SCRIPT")

    # 提取 --max-model-len
    if [[ "$content" =~ --max-model-len[[:space:]]+([0-9]+) ]]; then
        EXTRACTED_MAX_MODEL_LEN="${BASH_REMATCH[1]}"
    fi

    # 提取 --gpu-memory-utilization
    if [[ "$content" =~ --gpu-memory-utilization[[:space:]]+([0-9.]+) ]]; then
        EXTRACTED_GPU_MEM_UTIL="${BASH_REMATCH[1]}"
    fi

    # 提取 -q / --quantization
    if [[ "$content" =~ -q[[:space:]]+([a-z_]+) ]]; then
        EXTRACTED_QUANTIZATION="${BASH_REMATCH[1]}"
    fi

    # 提取 --dtype
    if [[ "$content" =~ --dtype[[:space:]]+([a-z0-9_]+) ]]; then
        EXTRACTED_DTYPE="${BASH_REMATCH[1]}"
    fi

    # 提取 --max-num-seqs
    if [[ "$content" =~ --max-num-seqs[[:space:]]+([0-9]+) ]]; then
        EXTRACTED_MAX_NUM_SEQS="${BASH_REMATCH[1]}"
    fi

    # 提取 --max_num_batched_tokens
    if [[ "$content" =~ --max_num_batched_tokens[[:space:]]+([0-9]+) ]]; then
        EXTRACTED_MAX_NUM_BATCHED_TOKENS="${BASH_REMATCH[1]}"
    fi

    # 提取 VLLM_* / NCCL_* 环境变量（支持数字如 RANK0_NUMA）
    while IFS= read -r line; do
        if [[ "$line" =~ export[[:space:]]+(VLLM_[[:alnum:]_]+|NCCL_[[:alnum:]_]+) ]]; then
            EXTRACTED_ENV_VARS+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$content"
}

# 1.5 输出校验报告
print_validation_report() {
    echo ""
    echo "============================================================"
    echo "脚本校验报告: $(basename "$SERVER_SCRIPT")"
    echo "============================================================"

    for ok in "${VALIDATION_OKS[@]}"; do
        echo -e "${GREEN}✅${NC} $ok"
    done

    for warn in "${VALIDATION_WARNINGS[@]}"; do
        echo -e "${YELLOW}⚠️${NC} $warn"
    done

    for err in "${VALIDATION_ERRORS[@]}"; do
        echo -e "${RED}❌${NC} $err"
    done

    echo ""
    echo "------------------------------------------------------------"
    echo "关键参数:"

    [[ -n "$EXTRACTED_MAX_MODEL_LEN" ]] && echo "  max-model-len: $EXTRACTED_MAX_MODEL_LEN"
    [[ -n "$EXTRACTED_GPU_MEM_UTIL" ]] && echo "  gpu-memory-utilization: $EXTRACTED_GPU_MEM_UTIL"
    [[ -n "$EXTRACTED_QUANTIZATION" ]] && echo "  量化方式: $EXTRACTED_QUANTIZATION"
    [[ -n "$EXTRACTED_DTYPE" ]] && echo "  dtype: $EXTRACTED_DTYPE"
    [[ -n "$EXTRACTED_MAX_NUM_SEQS" ]] && echo "  max-num-seqs: $EXTRACTED_MAX_NUM_SEQS"
    [[ -n "$EXTRACTED_MAX_NUM_BATCHED_TOKENS" ]] && echo "  max_num_batched_tokens: $EXTRACTED_MAX_NUM_BATCHED_TOKENS"

    if [[ ${#EXTRACTED_ENV_VARS[@]} -gt 0 ]]; then
        echo "  环境变量: ${EXTRACTED_ENV_VARS[*]}"
    fi

    echo "============================================================"
    echo ""
}

# ============================================================
# 阶段 2: 规范化与注册
# ============================================================

# 2.1 复制服务脚本
copy_server_script() {
    local dest="${SKILL_ROOT}/scripts/server-scripts/run_${MODEL_SHORT}-server.sh"

    log_info "复制服务脚本到: $dest"

    if [[ -f "$dest" ]]; then
        log_warn "目标文件已存在: $dest"
        if [[ "$YES_FLAG" != "true" || "$OVERWRITE_FLAG" != "true" ]]; then
            log_error "拒绝覆盖已有服务脚本；如需覆盖，请显式传入 --yes --overwrite"
            exit 1
        fi
    fi

    cp "$SERVER_SCRIPT" "$dest"
    chmod +x "$dest"
    log_ok "服务脚本已复制"
}

# 2.2 生成 Profile
generate_profile() {
    local profile_file="${PROFILES_DIR}/${MODEL_SHORT}.yaml"

    log_info "生成模型 Profile: $profile_file"

    if [[ -f "$profile_file" ]]; then
        log_warn "目标文件已存在: $profile_file"
        if [[ "$YES_FLAG" != "true" || "$OVERWRITE_FLAG" != "true" ]]; then
            log_warn "跳过 Profile 生成；如需覆盖，请显式传入 --yes --overwrite"
            return 0
        fi
    fi

    # 推导精度
    local precision="$PRECISION"
    if [[ -z "$precision" ]]; then
        case "$MODEL_SHORT" in
            *int8) precision="int8" ;;
            *fp8) precision="fp8" ;;
            *) precision="bf16" ;;
        esac
    fi

    cat > "$profile_file" << EOF
# 模型 Profile: $MODEL_NAME
# 自动生成于: $(date "+%Y-%m-%d %H:%M:%S")
# 源脚本: $(basename "$SERVER_SCRIPT")

model:
  display_name: "$MODEL_NAME"
  short_name: "$MODEL_SHORT"
  host_model_path: null
  container_model_path: "${MODEL_PATH:-/model/${MODEL_NAME}}"
  served_model_id: null
  bench_model_id: null
  precision: "$precision"

resource:
  default_tp: $TP
  min_gpu: $TP
  default_port: $PORT

service:
  script: "scripts/server-scripts/run_${MODEL_SHORT}-server.sh"
  vllm_params:
EOF

    [[ -n "$EXTRACTED_MAX_MODEL_LEN" ]] && \
        echo "    max_model_len: $EXTRACTED_MAX_MODEL_LEN" >> "$profile_file"
    [[ -n "$EXTRACTED_GPU_MEM_UTIL" ]] && \
        echo "    gpu_memory_utilization: $EXTRACTED_GPU_MEM_UTIL" >> "$profile_file"
    [[ -n "$EXTRACTED_QUANTIZATION" ]] && \
        echo "    quantization: \"$EXTRACTED_QUANTIZATION\"" >> "$profile_file"
    [[ -n "$EXTRACTED_DTYPE" ]] && \
        echo "    dtype: \"$EXTRACTED_DTYPE\"" >> "$profile_file"
    [[ -n "$EXTRACTED_MAX_NUM_SEQS" ]] && \
        echo "    max_num_seqs: $EXTRACTED_MAX_NUM_SEQS" >> "$profile_file"
    [[ -n "$EXTRACTED_MAX_NUM_BATCHED_TOKENS" ]] && \
        echo "    max_num_batched_tokens: $EXTRACTED_MAX_NUM_BATCHED_TOKENS" >> "$profile_file"

    echo "  env_vars:" >> "$profile_file"
    for var in "${EXTRACTED_ENV_VARS[@]}"; do
        echo "    - $var" >> "$profile_file"
    done

    cat >> "$profile_file" << EOF

health_check:
  endpoint: "/v1/chat/completions"
  prompt: "你好"
  timeout_seconds: 300
EOF

    log_ok "模型 Profile 已生成"
}

# 2.3 生成 task.yaml 模板
generate_task_template() {
    local task_file="${EXAMPLES_DIR}/${MODEL_SHORT}-test-task.yaml"

    log_info "生成 task.yaml 模板: $task_file"

    if [[ -f "$task_file" ]]; then
        log_warn "目标文件已存在: $task_file"
        if [[ "$YES_FLAG" != "true" || "$OVERWRITE_FLAG" != "true" ]]; then
            log_warn "跳过 task.yaml 生成；如需覆盖，请显式传入 --yes --overwrite"
            return 0
        fi
    fi

    cat > "$task_file" << EOF
task:
  name: vllm_perf_${MODEL_SHORT}
  run_id: auto
  owner: <user>
  description: "$MODEL_NAME 性能测试"

mode: single

paths:
  skill_host_root: /public/home/<user>/.claude/skills/vllm-perf-validation-single
  skill_container_root: /mnt/.claude/skills/vllm-perf-validation-single
  output_host_root: /public/home/<user>/skilltest/vllm-perf-validation-single
  output_container_root: /mnt/skilltest/vllm-perf-validation-single

image:
  name: null
  pull_policy: if_not_present

node:
  ip: null
  dcu_type: null
  gpu_count: 8

container:
  name_template: "<container_prefix>-<MMDD>-<MODEL_SHORT>-<IMAGE_PREFIX>"
  create_options:
    - --privileged
    - --network=host
    - --device=/dev/kfd
    - --device=/dev/dri
    - --ipc=host
    - --group-add=video
    - --cap-add=SYS_PTRACE
    - --security-opt=seccomp=unconfined
    - --ulimit=stack=-1:-1
    - --ulimit=memlock=-1:-1
  volumes:
    - /public/home/<user>:/mnt
    - /module:/module:ro
    - /public/opendas/DL_DATA/llm-models:/model:ro
    - /public4/share:/model1:ro
    - /public4/opendas/DL_DATA:/model2:ro
    - /opt/hyhal:/opt/hyhal:ro

ops:
  preflight_script: scripts/ops/preflight_node.sh
  create_container_script: scripts/ops/create_container.sh
  start_service_script: scripts/ops/start_vllm_service.sh
  wait_ready_script: scripts/ops/wait_vllm_ready.sh
  run_bench_script: scripts/ops/run_bench.sh
  stop_service_script: scripts/ops/stop_service.sh
  render_report_script: scripts/ops/render_report.py

models:
  - name: "$MODEL_NAME"
    model_short: "$MODEL_SHORT"
    host_model_path: null
    container_model_path: "${MODEL_PATH:-/model/${MODEL_NAME}}"
    served_model_id: null
    bench_model_id: null
    tp: $TP
    port: $PORT
    gpu_range: "0,1,2,3,4,5,6,7"
    service_script: scripts/server-scripts/run_${MODEL_SHORT}-server.sh

service:
  health_check:
    endpoint: /v1/chat/completions
    prompt: "你好"
    timeout_seconds: 300

test:
  mode: full
  script: scripts/client-scripts/run_perf_test-full.sh
  params:
    pairs:
      - input_len: 512
        output_len: 512
        max_batch: 128
      - input_len: 1024
        output_len: 1024
        max_batch: 64
      - input_len: 4096
        output_len: 1024
        max_batch: 64
    batch_seq: [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024]

output:
  work_dir: /public/home/<user>/skilltest/vllm-perf-validation-single/work_dirs
  report_dir: /public/home/<user>/skilltest/vllm-perf-validation-single/reports
  log_dir: /public/home/<user>/skilltest/vllm-perf-validation-single/logs
  csv_dir: /public/home/<user>/skilltest/vllm-perf-validation-single/csvs
EOF

    log_ok "task.yaml 模板已生成"
}

# 2.4 更新 MODEL_SHORT 映射表
update_model_short_mapping() {
    log_info "更新 MODEL_SHORT 映射表..."

    # 推导精度
    local precision="$PRECISION"
    if [[ -z "$precision" ]]; then
        case "$MODEL_SHORT" in
            *int8) precision="INT8" ;;
            *fp8) precision="FP8" ;;
            *) precision="bf16" ;;
        esac
    fi

    local entry="| $MODEL_NAME | $MODEL_SHORT | $precision |"

    if [[ ! -f "$CONVENTIONS_FILE" ]]; then
        log_error "conventions.md 不存在，请先创建"
        return 1
    fi

    # 检查是否已存在
    if grep -q "| $MODEL_NAME |" "$CONVENTIONS_FILE"; then
        log_warn "模型 $MODEL_NAME 已存在于映射表"
        return 0
    fi

    # 追加到 MODEL_SHORT 映射表末尾，避免依赖固定行号。
    if command -v python3 &> /dev/null; then
        python3 -c "
import re
with open('$CONVENTIONS_FILE', 'r') as f:
    lines = f.read().split('\n')
new_lines = []
inserted = False
for line in lines:
    if not inserted and line.startswith('---'):
        new_lines.append('$entry')
        inserted = True
    new_lines.append(line)
if not inserted:
    if new_lines and new_lines[-1] != '':
        new_lines.append('')
    new_lines.append('$entry')
with open('$CONVENTIONS_FILE', 'w') as f:
    f.write('\n'.join(new_lines))
"
    else
        # fallback: 使用 sed（Linux 兼容）
        sed -i "0,/^|.*|.*|$/{/^|.*|.*|$/a $entry
}" "$CONVENTIONS_FILE"
    fi

    log_ok "MODEL_SHORT 映射表已更新"
}

# ============================================================
# 阶段 3: 输出变更摘要
# ============================================================
print_summary() {
    echo ""
    echo "============================================================"
    echo -e "${GREEN}模型扩展完成！变更摘要：${NC}"
    echo "============================================================"
    echo ""
    echo "新增文件:"
    echo -e "  ${GREEN}✅${NC} scripts/server-scripts/run_${MODEL_SHORT}-server.sh"
    echo -e "  ${GREEN}✅${NC} references/profiles/${MODEL_SHORT}.yaml"
    echo -e "  ${GREEN}✅${NC} references/examples/${MODEL_SHORT}-test-task.yaml"
    echo ""
    echo "更新文件:"
    echo -e "  ${GREEN}✅${NC} references/conventions.md（追加 MODEL_SHORT 映射）"
    echo ""
    echo "待用户填写（task.yaml 模板中）:"
    echo -e "  ${YELLOW}⚠️${NC} image.name - 请指定 Docker 镜像"
    echo -e "  ${YELLOW}⚠️${NC} node.ip - 请指定目标节点 IP"
    echo -e "  ${YELLOW}⚠️${NC} node.dcu_type - 请指定 DCU 类型（DCU/BW1000/BW1100）"
    echo ""
    echo "============================================================"
    echo "使用方式:"
    echo "  1. 编辑 references/examples/${MODEL_SHORT}-test-task.yaml"
    echo "  2. 填写 image.name, node.ip, node.dcu_type, host_model_path"
    echo "  3. 按顺序使用 scripts/ops/preflight_node.sh、create_container.sh、start_vllm_service.sh、wait_vllm_ready.sh、run_bench.sh、stop_service.sh、render_report.py 执行"
    echo "  4. 不要复制生成器里的 YAML 片段去手写 docker run 长命令；容器创建以 scripts/ops/create_container.sh 为准"
    echo "============================================================"
    echo ""
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo ""
    echo "============================================================"
    echo -e "${BLUE}add-model.sh - vLLM 性能验证模型扩展工具${NC}"
    echo "============================================================"
    echo ""

    # 参数解析
    parse_args "$@"

    # 确保 profiles 目录存在
    mkdir -p "$PROFILES_DIR"

    # 阶段 1: 校验
    echo ""
    echo ">>> 阶段 1: 脚本校验"
    echo "------------------------------------------------------------"

    if ! validate_script_syntax; then
        print_validation_report
        log_error "脚本校验失败，退出"
        exit 1
    fi

    validate_executable
    validate_parameterization
    extract_vllm_params
    print_validation_report

    # 检查是否有严重错误（硬编码问题）
    if [[ ${#VALIDATION_ERRORS[@]} -gt 0 ]]; then
        echo ""
        log_warn "检测到参数化问题，是否继续?"
        if [[ "$YES_FLAG" == "true" ]] || [[ ! -t 0 ]]; then
            confirm="y"
        else
            read -p "继续执行? (y/N): " confirm
        fi
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_error "用户取消操作"
            exit 0
        fi
    fi

    # 阶段 2: 规范化与注册
    echo ""
    echo ">>> 阶段 2: 规范化与注册"
    echo "------------------------------------------------------------"

    copy_server_script
    generate_profile
    generate_task_template
    update_model_short_mapping

    # 阶段 3: 输出变更摘要
    print_summary
}

main "$@"

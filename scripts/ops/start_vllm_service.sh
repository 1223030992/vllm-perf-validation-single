#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  start_vllm_service.sh --node NODE --container NAME --model-name NAME \
    --model-short SHORT --container-model-path PATH --server-script SCRIPT \
    --test-mode MODE --port PORT --tp TP --gpu-range RANGE \
    [--host-model-path PATH] [--image IMAGE]

选项:
  --dry-run

环境变量:
  SKILL_CONTAINER_ROOT=/mnt/.claude/skills/vllm-perf-validation-single
  OUTPUT_CONTAINER_ROOT=/mnt/skilltest/vllm-perf-validation-single
  OUTPUT_HOST_ROOT=/public/home/<user>/skilltest/vllm-perf-validation-single
  旧版 dry-run 环境变量仍兼容；正式调用请使用 --dry-run。

说明:
  --server-script 可传相对路径、./ 开头路径或容器内绝对路径。
  本脚本通过 stdin 写入容器临时脚本，再用 bash -ic 执行，避免 SSH/Docker/Bash 多层引号截断。
USAGE
}

quote_sh() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

resolve_server_script() {
  local script="$1"
  local marker="/.claude/skills/vllm-perf-validation-single/"
  if [[ -z "$script" ]]; then
    echo "服务启动脚本不能为空" >&2
    return 2
  fi
  if [[ "$script" == "$SKILL_CONTAINER_ROOT"* ]]; then
    printf '%s\n' "$script"
    return 0
  fi
  if [[ "$script" == /* ]]; then
    if [[ "$script" == *"$marker"* ]]; then
      printf '%s/%s\n' "${SKILL_CONTAINER_ROOT%/}" "${script#*${marker}}"
      return 0
    fi
    echo "unsupported absolute server script path: $script" >&2
    echo "please pass a relative path like scripts/server-scripts/run_xxx.sh, or a container path under ${SKILL_CONTAINER_ROOT}" >&2
    return 2
  fi
  script="${script#./}"
  printf '%s/%s\n' "${SKILL_CONTAINER_ROOT%/}" "$script"
}

to_host_path() {
  local path="$1"
  if [[ "$path" == "$OUTPUT_CONTAINER_ROOT"* ]]; then
    printf '%s%s\n' "$OUTPUT_HOST_ROOT" "${path#$OUTPUT_CONTAINER_ROOT}"
  else
    printf '%s\n' "$path"
  fi
}

run_in_container() {
  local workdir="$1"
  local script="$2"
  local docker_cmd
  docker_cmd="docker exec -i -w $(quote_sh "$workdir") $(quote_sh "$CONTAINER") bash -ic 'tmp=/tmp/vllm_ops_start_\$\$.sh; cat > \"\$tmp\"; bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc'"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "即将在容器内执行启动脚本:"
    printf 'ssh %q %q\n' "$NODE" "$docker_cmd"
    echo "--- container script ---"
    printf '%s\n' "$script"
    return 0
  fi
  printf '%s\n' "$script" | ssh "$NODE" "$docker_cmd"
}

NODE=""
CONTAINER=""
MODEL_NAME=""
MODEL_SHORT=""
CONTAINER_MODEL_PATH=""
HOST_MODEL_PATH=""
SERVER_SCRIPT=""
IMAGE=""
TEST_MODE="custom"
PORT=""
TP=""
GPU_RANGE="0,1,2,3,4,5,6,7"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/runtime_config.sh"
SKILL_USER=""
USER_ABBR=""
HOME_ROOT=""
HOST_HOME_ROOT=""
SKILL_HOST_ROOT=""
OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-}"
OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-}"
CONTAINER_PREFIX=""
DRY_RUN="${DRY_RUN:-0}"
DATE_PART="$(date +%Y%m%d)"
MMDD="$(date +%m%d)"

while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then
    shift 2
    continue
  fi
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --model-name) MODEL_NAME="$2"; shift 2 ;;
    --model-short) MODEL_SHORT="$2"; shift 2 ;;
    --container-model-path) CONTAINER_MODEL_PATH="$2"; shift 2 ;;
    --host-model-path) HOST_MODEL_PATH="$2"; shift 2 ;;
    --server-script) SERVER_SCRIPT="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --test-mode) TEST_MODE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --tp) TP="$2"; shift 2 ;;
    --gpu-range) GPU_RANGE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

for var in NODE CONTAINER MODEL_NAME MODEL_SHORT CONTAINER_MODEL_PATH SERVER_SCRIPT PORT TP; do
  [[ -n "${!var}" ]] || { echo "缺少参数: ${var}" >&2; exit 2; }
done
resolve_runtime_config

WORK_DIR="${OUTPUT_CONTAINER_ROOT}/work_dirs/${MODEL_NAME}-${TEST_MODE}-${DATE_PART}-${CONTAINER}"
LOG="${WORK_DIR}/logs/${MODEL_SHORT}-${MMDD}-vllm-server.log"
PID="${WORK_DIR}/logs/${MODEL_SHORT}-${MMDD}-vllm-server.pid"
STATE="${WORK_DIR}/state.json"
SERVER_PATH="$(resolve_server_script "$SERVER_SCRIPT")"

WORK_DIR_HOST="$(to_host_path "$WORK_DIR")"
LOG_HOST="$(to_host_path "$LOG")"
PID_HOST="$(to_host_path "$PID")"
STATE_HOST="$(to_host_path "$STATE")"

remote_script=$(cat <<EOF
set -euo pipefail
SKILL_CONTAINER_ROOT=$(quote_sh "$SKILL_CONTAINER_ROOT")
WORK_DIR=$(quote_sh "$WORK_DIR")
WORK_DIR_HOST=$(quote_sh "$WORK_DIR_HOST")
LOG=$(quote_sh "$LOG")
LOG_HOST=$(quote_sh "$LOG_HOST")
PID=$(quote_sh "$PID")
PID_HOST=$(quote_sh "$PID_HOST")
STATE=$(quote_sh "$STATE")
STATE_HOST=$(quote_sh "$STATE_HOST")
SERVER_PATH=$(quote_sh "$SERVER_PATH")

restore_work_dir_permissions() {
  if [[ -d "\$WORK_DIR" ]]; then
    HOST_OWNER=\$(stat -c '%u:%g' /mnt 2>/dev/null || true)
    if [[ -n "\$HOST_OWNER" ]]; then
      chown -R "\$HOST_OWNER" "\$WORK_DIR" 2>/dev/null || true
    fi
    chmod -R u+rwX,go+rX "\$WORK_DIR" 2>/dev/null || true
  fi
}
trap restore_work_dir_permissions EXIT

if [[ ! -f "\$SERVER_PATH" ]]; then
  echo "服务启动脚本不存在: \$SERVER_PATH" >&2
  exit 1
fi

mkdir -p "\${WORK_DIR}/logs"
rm -f "\$LOG" "\$PID"
START_TS=\$(date +%s)

python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
  --set "status=SERVICE_STARTING" \
  --set "node=$(printf '%s' "$NODE")" \
  --set "container.name=$(printf '%s' "$CONTAINER")" \
  --set "image=$(printf '%s' "$IMAGE")" \
  --set "model.name=$(printf '%s' "$MODEL_NAME")" \
  --set "model.model_short=$(printf '%s' "$MODEL_SHORT")" \
  --set "model.host_model_path=$(printf '%s' "$HOST_MODEL_PATH")" \
  --set "model.container_model_path=$(printf '%s' "$CONTAINER_MODEL_PATH")" \
  --set "model.tp=$(printf '%s' "$TP")" \
  --set "model.port=$(printf '%s' "$PORT")" \
  --set "model.gpu_range=$(printf '%s' "$GPU_RANGE")" \
  --set "model.service_script=\$SERVER_PATH" \
  --set "paths.work_dir=\$WORK_DIR" \
  --set "paths.work_dir_container=\$WORK_DIR" \
  --set "paths.work_dir_host=\$WORK_DIR_HOST" \
  --set "paths.state_file=\$STATE" \
  --set "paths.state_file_container=\$STATE" \
  --set "paths.state_file_host=\$STATE_HOST" \
  --set "paths.log_file=\$LOG" \
  --set "paths.log_file_container=\$LOG" \
  --set "paths.log_file_host=\$LOG_HOST" \
  --set "paths.pid_file=\$PID" \
  --set "paths.pid_file_container=\$PID" \
  --set "paths.pid_file_host=\$PID_HOST" \
  --set "timing.service_start_epoch=\$START_TS"

export MODEL_PATH=$(quote_sh "$CONTAINER_MODEL_PATH")
export PORT=$(quote_sh "$PORT")
export TP=$(quote_sh "$TP")
export TP_SIZE=$(quote_sh "$TP")
export GPU_RANGE=$(quote_sh "$GPU_RANGE")
export LOG_DIR="\${WORK_DIR}/logs"

nohup bash "\$SERVER_PATH" > "\$LOG" 2>&1 &
echo \$! > "\$PID"
SERVICE_PID=\$(cat "\$PID")
STARTUP_DURATION=\$((\$(date +%s) - START_TS))

python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
  --set "status=SERVICE_STARTED" \
  --set "container.service_pid=\$SERVICE_PID" \
  --set "timing.startup_duration_seconds=\$STARTUP_DURATION"

sleep 10
echo "WORK_DIR_CONTAINER=\$WORK_DIR"
echo "WORK_DIR_HOST=\$WORK_DIR_HOST"
echo "LOG_CONTAINER=\$LOG"
echo "LOG_HOST=\$LOG_HOST"
echo "PID_CONTAINER=\$PID"
echo "PID_HOST=\$PID_HOST"
echo "STATE_CONTAINER=\$STATE"
echo "STATE_HOST=\$STATE_HOST"
echo "=== PID ==="
cat "\$PID" || true
echo "=== PROC ==="
ps aux | grep -E "vllm|ray|python|APIServer" | grep -v grep || true
echo "=== LOG_TAIL ==="
tail -120 "\$LOG" || true
EOF
)

run_in_container "$SKILL_CONTAINER_ROOT" "$remote_script"

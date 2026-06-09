#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  wait_vllm_ready.sh --node NODE --container NAME --port PORT --log LOG --model-path PATH [--state STATE]

选项:
  --timeout SECONDS       默认: 1800
  --interval SECONDS      默认: 60
  --verbose [0|1]         输出每轮轮询详情，等价于 VERBOSE=1；可选值兼容旧调用
  --dry-run               只打印将要执行的远端检查，不连接节点

环境变量:
  旧版 dry-run 环境变量仍兼容；正式调用请使用 --dry-run
  VERBOSE=1               输出每轮轮询详情

成功输出:
  SERVED_MODEL_ID=<id>

说明:
  本脚本在容器内循环检查进程、日志、端口、/v1/models 和 API 健康状态。
  脚本通过 stdin 写入容器临时脚本再执行，避免多层引号导致 EOF 错误。
USAGE
}

quote_sh() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

run_in_container() {
  local script="$1"
  local docker_cmd
  docker_cmd="docker exec -i $(quote_sh "$CONTAINER") bash -ic 'tmp=/tmp/vllm_ops_wait_\$\$.sh; cat > \"\$tmp\"; bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc'"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "即将在容器内执行就绪检查:"
    printf 'ssh %q %q\n' "$NODE" "$docker_cmd"
    echo "--- container script ---"
    printf '%s\n' "$script"
    return 0
  fi
  printf '%s\n' "$script" | ssh "$NODE" "$docker_cmd"
}

NODE=""
CONTAINER=""
PORT=""
LOG=""
MODEL_PATH=""
STATE=""
TIMEOUT=1800
INTERVAL=60
DRY_RUN="${DRY_RUN:-0}"
SKILL_CONTAINER_ROOT="${SKILL_CONTAINER_ROOT:-/mnt/.claude/skills/vllm-perf-validation-single}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    --model-path) MODEL_PATH="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose)
      if [[ $# -ge 2 && "$2" != --* ]]; then
        VERBOSE="$2"
        shift 2
      else
        VERBOSE=1
        shift
      fi
      ;;
    --help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

for var in NODE CONTAINER PORT LOG MODEL_PATH; do
  [[ -n "${!var}" ]] || { echo "缺少参数: ${var}" >&2; exit 2; }
done
if [[ -z "$STATE" ]]; then
  STATE="$(dirname "$(dirname "$LOG")")/state.json"
fi

remote_script=$(cat <<EOF
set -euo pipefail
PORT=$(quote_sh "$PORT")
LOG=$(quote_sh "$LOG")
MODEL_PATH=$(quote_sh "$MODEL_PATH")
STATE=$(quote_sh "$STATE")
TIMEOUT=$(quote_sh "$TIMEOUT")
INTERVAL=$(quote_sh "$INTERVAL")
VERBOSE=$(quote_sh "${VERBOSE:-0}")
SKILL_CONTAINER_ROOT=$(quote_sh "$SKILL_CONTAINER_ROOT")
FAIL_RE="Traceback|ImportError|ModuleNotFoundError|RuntimeError|Killed|OOM|out[[:space:]]of[[:space:]]memory|hipError|ROCm[[:space:]]error"
START_TS=\$(date +%s)
LAST_TAIL=""
LAST_HEALTH_BODY=""
WORK_DIR=\$(dirname "\$(dirname "\$STATE")")

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

python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
  --set "status=WAITING_READY" \
  --set "timing.readiness_start_epoch=\$START_TS" \
  --set "timing.readiness_timeout_seconds=\$TIMEOUT"

echo "开始等待 vLLM 服务就绪，端口: \$PORT，超时: \$TIMEOUT 秒"

while true; do
  NOW_TS=\$(date +%s)
  ELAPSED=\$((NOW_TS - START_TS))
  if (( ELAPSED >= TIMEOUT )); then
    python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
      --set "status=SERVICE_TIMEOUT" \
      --set "failure.reason=readiness_timeout" \
      --set "service.last_health_body=\$LAST_HEALTH_BODY" \
      --set "timing.readiness_duration_seconds=\$ELAPSED"
    echo "SERVICE_TIMEOUT"
    echo "\$LAST_TAIL"
    exit 1
  fi

  PROC_OUT=\$(ps aux | grep -E "vllm|ray|python|APIServer" | grep -v grep || true)
  LOG_TAIL=\$(tail -80 "\$LOG" 2>/dev/null || true)
  LAST_TAIL="\$LOG_TAIL"

  ACTUAL_PORT=\$(printf '%s\n' "\$LOG_TAIL" | sed -nE 's/.*Starting vLLM API server.*:([0-9]+).*/\1/p' | tail -1 || true)
  if [[ -n "\$ACTUAL_PORT" && "\$ACTUAL_PORT" != "\$PORT" ]]; then
    python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
      --set "status=SERVICE_PORT_MISMATCH" \
      --set "failure.reason=service_port_mismatch" \
      --set "failure.expected_port=\$PORT" \
      --set "failure.actual_port=\$ACTUAL_PORT" \
      --set "service.actual_port=\$ACTUAL_PORT" \
      --set "timing.readiness_duration_seconds=\$ELAPSED"
    echo "SERVICE_PORT_MISMATCH: expected \$PORT but vLLM is listening on \$ACTUAL_PORT"
    echo "\$LOG_TAIL"
    exit 1
  fi

  if [[ "\$LOG_TAIL" =~ \$FAIL_RE ]]; then
    python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
      --set "status=SERVICE_FAILED" \
      --set "failure.reason=log_failure_signal" \
      --set "timing.readiness_duration_seconds=\$ELAPSED"
    echo "SERVICE_FAILED"
    echo "\$LOG_TAIL"
    exit 1
  fi

  if [[ -z "\$PROC_OUT" ]]; then
    python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
      --set "status=SERVICE_PROCESS_MISSING" \
      --set "failure.reason=service_process_missing" \
      --set "timing.readiness_duration_seconds=\$ELAPSED"
    echo "SERVICE_PROCESS_MISSING"
    echo "\$LOG_TAIL"
    exit 1
  fi

  MODELS_JSON=\$(curl -sS -m 20 "http://127.0.0.1:\$PORT/v1/models" 2>/dev/null || true)
  SERVED_MODEL_ID=\$(MODELS_JSON="\$MODELS_JSON" python3 - <<'PY' 2>/dev/null | head -1
import json
import os

try:
    obj = json.loads(os.environ.get("MODELS_JSON", ""))
    rows = obj.get("data") or []
    print(rows[0].get("id", "") if rows else "")
except Exception:
    print("")
PY
)

  if [[ -n "\$SERVED_MODEL_ID" ]]; then
    HEALTH_PAYLOAD=\$(python3 - "\$SERVED_MODEL_ID" <<'PY'
import json
import sys

payload = {
    "model": sys.argv[1],
    "temperature": 0,
    "top_p": 1,
    "max_tokens": 16,
    "messages": [{"role": "user", "content": "你好"}],
}
print(json.dumps(payload, ensure_ascii=False))
PY
)
    HEALTH_CODE=\$(curl -sS -m 20 -o /tmp/vllm-health.json -w "%{http_code}" \
      -X POST "http://127.0.0.1:\$PORT/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "\$HEALTH_PAYLOAD" 2>/dev/null || true)
    LAST_HEALTH_BODY=\$(head -c 2000 /tmp/vllm-health.json 2>/dev/null || true)

    if [[ "\$HEALTH_CODE" == "200" ]]; then
      python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
        --set "status=READY" \
        --set "model.served_model_id=\$SERVED_MODEL_ID" \
        --set "model.bench_model_id=\$SERVED_MODEL_ID" \
        --set "service.health_code=200" \
        --set "service.models_json_summary=\$MODELS_JSON" \
        --set "timing.readiness_duration_seconds=\$ELAPSED"
      echo "SERVED_MODEL_ID=\$SERVED_MODEL_ID"
      exit 0
    fi

    python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
      --set "model.served_model_id=\$SERVED_MODEL_ID" \
      --set "service.health_code=\$HEALTH_CODE" \
      --set "service.last_health_body=\$LAST_HEALTH_BODY" >/dev/null

    if [[ "\$VERBOSE" == "1" ]]; then
      echo "已发现模型 \$SERVED_MODEL_ID，但健康检查返回 \$HEALTH_CODE，继续等待"
      echo "\$LAST_HEALTH_BODY"
    fi
  else
    [[ "\$VERBOSE" == "1" ]] && echo "服务进程存在，但 /v1/models 尚未返回模型，已等待 \$ELAPSED 秒"
  fi

  sleep "\$INTERVAL"
done
EOF
)

run_in_container "$remote_script"

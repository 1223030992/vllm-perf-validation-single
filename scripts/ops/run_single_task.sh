#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  run_single_task.sh --profile PROFILE_OR_SHORT --node NODE --image IMAGE \
    --test-mode custom|pchit [test options]

  run_single_task.sh --node NODE --image IMAGE --model-name NAME --model-short SHORT \
    --host-model-path PATH --container-model-path PATH --server-script SCRIPT \
    --port PORT --tp TP --gpu-range RANGE --test-mode custom \
    --input-lens "512" --output-len 32 --concurrencies "1" \
    --num-prompts-mult 1 --percentiles "50,95,99" [--assume-yes]

  run_single_task.sh --node NODE --image IMAGE --model-name NAME --model-short SHORT \
    --host-model-path PATH --container-model-path PATH --server-script SCRIPT \
    --port PORT --tp TP --gpu-range RANGE --test-mode pchit \
    --input-len 32768 --output-len 1024 --pc-hit-target 90 \
    --batches "1,2,3,4,5,6,7,8" [--pchit-benchmark-mode fixed]

Common options:
  --user USER
  --abbr ABBR
  --home-root PATH
  --host-home-root PATH
  --skill-host-root PATH
  --output-host-root PATH
  --output-container-root PATH
  --profile PROFILE_OR_SHORT
  --date MMDD
  --image-prefix PREFIX
  --container NAME
  --container-prefix PREFIX
  --run-id ID
  --timeout SECONDS
  --interval SECONDS
  --report-dir PATH
  --assume-yes
  --dry-run
  --allow-image-prefix-fallback
USAGE
}

confirm_or_exit() {
  local message="$1"
  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi
  printf '%s [type yes to continue]: ' "$message" >&2
  read -r answer
  case "$answer" in
    yes|YES|y|Y) return 0 ;;
    *) echo "User did not confirm; stop." >&2; exit 1 ;;
  esac
}

tag_prefix_from_image() {
  local image="$1"
  local base
  base="${image##*:}"
  base="${base##*/}"
  base="$(printf '%s' "$base" | tr -cd 'A-Za-z0-9')"
  printf '%s\n' "${base:0:4}"
}

inspect_image_prefix() {
  local image_id
  image_id="$(ssh "$NODE" "docker image inspect $(printf '%q' "$IMAGE") --format '{{.Id}}'" 2>/dev/null | head -1 || true)"
  image_id="${image_id#sha256:}"
  image_id="$(printf '%s' "$image_id" | tr -cd 'A-Za-z0-9')"
  if [[ ${#image_id} -ge 4 ]]; then
    printf '%s\n' "${image_id:0:4}"
    return 0
  fi
  if [[ "$ALLOW_IMAGE_PREFIX_FALLBACK" == "1" ]]; then
    echo "WARN: docker image inspect failed; fallback to image tag prefix." >&2
    tag_prefix_from_image "$IMAGE"
    return 0
  fi
  echo "Cannot resolve image id; confirm image exists or pass --image-prefix." >&2
  return 1
}

extract_value() {
  local key="$1"
  local file="$2"
  grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2-
}

resolve_profile_path() {
  local profile="$1"
  if [[ -f "$profile" ]]; then
    printf '%s\n' "$profile"
    return 0
  fi
  if [[ -f "${SKILL_ROOT}/references/profiles/${profile}" ]]; then
    printf '%s\n' "${SKILL_ROOT}/references/profiles/${profile}"
    return 0
  fi
  if [[ -f "${SKILL_ROOT}/references/profiles/${profile}.yaml" ]]; then
    printf '%s\n' "${SKILL_ROOT}/references/profiles/${profile}.yaml"
    return 0
  fi
  echo "profile not found: $profile" >&2
  echo "expected file path or short name under ${SKILL_ROOT}/references/profiles/" >&2
  return 2
}

load_profile_shell_vars() {
  local profile_path="$1"
  python3 - "$profile_path" <<'PY'
import shlex
import sys

path = sys.argv[1]
section = None
values = {}

def clean(value):
    value = value.strip()
    if value in ("null", "None", "~"):
        return ""
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        value = value[1:-1]
    return value

with open(path, "r", encoding="utf-8") as fh:
    for raw in fh:
        line = raw.rstrip("\n")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not line.startswith(" ") and stripped.endswith(":"):
            section = stripped[:-1]
            continue
        if section not in ("model", "resource", "service"):
            continue
        if ":" not in stripped:
            continue
        key, value = stripped.split(":", 1)
        values[(section, key.strip())] = clean(value)

mapping = {
    "PROFILE_MODEL_NAME": values.get(("model", "display_name"), ""),
    "PROFILE_MODEL_SHORT": values.get(("model", "short_name"), ""),
    "PROFILE_HOST_MODEL_PATH": values.get(("model", "host_model_path"), ""),
    "PROFILE_CONTAINER_MODEL_PATH": values.get(("model", "container_model_path"), ""),
    "PROFILE_PORT": values.get(("resource", "default_port"), ""),
    "PROFILE_TP": values.get(("resource", "default_tp"), ""),
    "PROFILE_SERVER_SCRIPT": values.get(("service", "script"), ""),
}

for key, value in mapping.items():
    print("%s=%s" % (key, shlex.quote(value)))
PY
}

resolve_server_script_for_container() {
  local script="$1"
  local marker="/.claude/skills/vllm-perf-validation-single/"
  if [[ -z "$script" ]]; then
    return 0
  fi
  if [[ "$script" == "$SKILL_CONTAINER_ROOT"* ]]; then
    printf '%s\n' "$script"
    return 0
  fi
  if [[ "$script" == /* ]]; then
    if [[ "$script" == *"$marker"* ]]; then
      printf '%s/%s\n' "${SKILL_CONTAINER_ROOT%/}" "${script#*${marker}}"
    else
      printf '%s\n' "$script"
    fi
  else
    script="${script#./}"
    printf '%s/%s\n' "${SKILL_CONTAINER_ROOT%/}" "$script"
  fi
}

run_step_capture() {
  local name="$1"
  local outfile="$2"
  shift 2
  echo "== ${name} =="
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY_RUN_STEP:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@" 2>&1 | tee "$outfile"
}

NODE=""
IMAGE=""
PROFILE=""
PROFILE_PATH=""
MODEL_NAME=""
MODEL_SHORT=""
HOST_MODEL_PATH=""
CONTAINER_MODEL_PATH=""
SERVER_SCRIPT=""
PORT=""
TP=""
GPU_RANGE=""
TEST_MODE="custom"
MODE="single"
INPUT_LENS=""
INPUT_LEN=""
OUTPUT_LEN=""
CONCURRENCIES=""
NUM_PROMPTS_MULT=""
PERCENTILES=""
REQUEST_RATE=""
CACHE_HIT_RATES=""
BATCHES=""
CONCURRENCY_MULTIPLIER=1
PC_HIT_TARGET=""
WARMUP_CACHE_HIT_RATES="92,95"
WARMUP_CONCURRENCY_MULTIPLIER=4
PC_HIT_TOLERANCE=1
PC_HIT_TIMEOUT=1800
PC_HIT_INTERVAL=30
PCHIT_BENCHMARK_MODE="fixed"
TTFT_SLA_MS=5000
TPOT_SLA_MS=50
SLA_STAT="mean"
PREFIX_WARMUP_REQUESTS=1
CASE_WARMUP_REPEATS=0
SKILL_USER=""
USER_ABBR=""
HOME_ROOT=""
HOST_HOME_ROOT=""
SKILL_HOST_ROOT=""
OUTPUT_HOST_ROOT=""
OUTPUT_CONTAINER_ROOT=""
DATE_PART="$(date +%m%d)"
IMAGE_PREFIX=""
CONTAINER=""
CONTAINER_PREFIX=""
RUN_ID=""
TIMEOUT=1800
TIMEOUT_SET=0
INTERVAL=60
ASSUME_YES=0
DRY_RUN=0
ALLOW_IMAGE_PREFIX_FALLBACK=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/runtime_config.sh"
OPS_VERSION="unknown"
if [[ -f "$SCRIPT_DIR/version.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/version.sh"
fi
REPORT_DIR=""

while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then
    shift 2
    continue
  fi
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --model-name) MODEL_NAME="$2"; shift 2 ;;
    --model-short) MODEL_SHORT="$2"; shift 2 ;;
    --host-model-path) HOST_MODEL_PATH="$2"; shift 2 ;;
    --container-model-path) CONTAINER_MODEL_PATH="$2"; shift 2 ;;
    --server-script|--service-script) SERVER_SCRIPT="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --tp|--TP) TP="$2"; shift 2 ;;
    --gpu-range) GPU_RANGE="$2"; shift 2 ;;
    --test-mode) TEST_MODE="$2"; shift 2 ;;
    --input-lens) INPUT_LENS="$2"; shift 2 ;;
    --input-len) INPUT_LEN="$2"; shift 2 ;;
    --output-len) OUTPUT_LEN="$2"; shift 2 ;;
    --concurrencies) CONCURRENCIES="$2"; shift 2 ;;
    --num-prompts-mult) NUM_PROMPTS_MULT="$2"; shift 2 ;;
    --percentiles) PERCENTILES="$2"; shift 2 ;;
    --request-rate) REQUEST_RATE="$2"; shift 2 ;;
    --cache-hit-rates) CACHE_HIT_RATES="$2"; shift 2 ;;
    --batches) BATCHES="$2"; shift 2 ;;
    --concurrency-multiplier) CONCURRENCY_MULTIPLIER="$2"; shift 2 ;;
    --pc-hit-target) PC_HIT_TARGET="$2"; shift 2 ;;
    --warmup-cache-hit-rates) WARMUP_CACHE_HIT_RATES="$2"; shift 2 ;;
    --warmup-concurrency-multiplier) WARMUP_CONCURRENCY_MULTIPLIER="$2"; shift 2 ;;
    --pc-hit-tolerance) PC_HIT_TOLERANCE="$2"; shift 2 ;;
    --pc-hit-timeout) PC_HIT_TIMEOUT="$2"; shift 2 ;;
    --pc-hit-interval) PC_HIT_INTERVAL="$2"; shift 2 ;;
    --pchit-benchmark-mode) PCHIT_BENCHMARK_MODE="$2"; shift 2 ;;
    --ttft-sla-ms) TTFT_SLA_MS="$2"; shift 2 ;;
    --tpot-sla-ms) TPOT_SLA_MS="$2"; shift 2 ;;
    --sla-stat) SLA_STAT="$2"; shift 2 ;;
    --prefix-warmup-requests) PREFIX_WARMUP_REQUESTS="$2"; shift 2 ;;
    --case-warmup-repeats) CASE_WARMUP_REPEATS="$2"; shift 2 ;;
    --date) DATE_PART="$2"; shift 2 ;;
    --image-prefix) IMAGE_PREFIX="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; TIMEOUT_SET=1; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    --assume-yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-image-prefix-fallback) ALLOW_IMAGE_PREFIX_FALLBACK=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

resolve_runtime_config

if [[ -n "$PROFILE" ]]; then
  PROFILE_PATH="$(resolve_profile_path "$PROFILE")"
  eval "$(load_profile_shell_vars "$PROFILE_PATH")"
  [[ -n "$MODEL_NAME" ]] || MODEL_NAME="$PROFILE_MODEL_NAME"
  [[ -n "$MODEL_SHORT" ]] || MODEL_SHORT="$PROFILE_MODEL_SHORT"
  [[ -n "$HOST_MODEL_PATH" ]] || HOST_MODEL_PATH="$PROFILE_HOST_MODEL_PATH"
  [[ -n "$CONTAINER_MODEL_PATH" ]] || CONTAINER_MODEL_PATH="$PROFILE_CONTAINER_MODEL_PATH"
  [[ -n "$SERVER_SCRIPT" ]] || SERVER_SCRIPT="$PROFILE_SERVER_SCRIPT"
  [[ -n "$PORT" ]] || PORT="$PROFILE_PORT"
  [[ -n "$TP" ]] || TP="$PROFILE_TP"
fi

for var in NODE IMAGE MODEL_NAME MODEL_SHORT HOST_MODEL_PATH CONTAINER_MODEL_PATH SERVER_SCRIPT PORT TP GPU_RANGE TEST_MODE; do
  [[ -n "${!var}" ]] || { echo "missing required argument: ${var}" >&2; exit 2; }
done

if [[ "$MODE" != "single" ]]; then
  echo "run_single_task.sh only supports --mode single; got: $MODE" >&2
  exit 2
fi

if [[ "$TEST_MODE" == "custom" ]]; then
  for var in INPUT_LENS OUTPUT_LEN CONCURRENCIES NUM_PROMPTS_MULT PERCENTILES; do
    [[ -n "${!var}" ]] || { echo "custom mode missing argument: ${var}" >&2; exit 2; }
  done
elif [[ "$TEST_MODE" == "pchit" ]]; then
  [[ -n "$INPUT_LEN" ]] || { echo "pchit mode missing --input-len" >&2; exit 2; }
  [[ -n "$OUTPUT_LEN" ]] || { echo "pchit mode missing --output-len" >&2; exit 2; }
  [[ -n "$PC_HIT_TARGET" ]] || { echo "pchit mode missing --pc-hit-target" >&2; exit 2; }
  [[ "$PCHIT_BENCHMARK_MODE" == "fixed" || "$PCHIT_BENCHMARK_MODE" == "sla-search" ]] || { echo "pchit --pchit-benchmark-mode must be fixed or sla-search" >&2; exit 2; }
  [[ "$SLA_STAT" == "mean" || "$SLA_STAT" == "p95" || "$SLA_STAT" == "p99" ]] || { echo "--sla-stat must be mean, p95, or p99" >&2; exit 2; }
  [[ -n "$CACHE_HIT_RATES" ]] || CACHE_HIT_RATES="$PC_HIT_TARGET"
  [[ -n "$BATCHES" ]] || BATCHES="1,2,3,4,5,6,7,8"
else
  echo "run_single_task.sh supports custom and pchit test modes; got: $TEST_MODE" >&2
  exit 2
fi

if [[ "$TIMEOUT_SET" == "0" ]]; then
  if [[ "$MODEL_SHORT" == glm5* && "$MODEL_SHORT" != glm51* ]]; then
    TIMEOUT=3600
  elif [[ "$MODEL_SHORT" == glm51* ]]; then
    TIMEOUT=2400
  fi
fi

if [[ -z "$IMAGE_PREFIX" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN does not inspect remote image id; pass --image-prefix to verify final container name." >&2
    IMAGE_PREFIX="AUTO"
  else
    IMAGE_PREFIX="$(inspect_image_prefix)"
  fi
fi
if [[ -z "$CONTAINER" ]]; then
  CONTAINER="${CONTAINER_PREFIX}-${DATE_PART}-${MODEL_SHORT}-${IMAGE_PREFIX}"
fi
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="${MODEL_SHORT}-${TEST_MODE}-$(date +%Y%m%d)-${CONTAINER}"
fi
if [[ -z "$REPORT_DIR" ]]; then
  REPORT_DIR="${OUTPUT_HOST_ROOT}/reports"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "TASK_RUN_ID=$RUN_ID"
echo "CONTAINER_NAME=$CONTAINER"
echo "IMAGE_PREFIX=$IMAGE_PREFIX"
echo "OPS_VERSION=$OPS_VERSION"
echo "ENTRYPOINT=$0"
if [[ -n "$PROFILE_PATH" ]]; then
  echo "PROFILE=$PROFILE_PATH"
fi
echo "REPORT_DIR=$REPORT_DIR"
echo "READY_TIMEOUT=$TIMEOUT"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "--dry-run: no SSH/Docker/GPU operation will be executed."
  echo "Execution sequence:"
  echo "  1. ensure_workspace.sh"
  echo "  2. preflight_node.sh"
  echo "  3. create_container.sh"
  echo "  4. start_vllm_service.sh"
  echo "  5. wait_vllm_ready.sh"
  echo "  6. run_bench.sh"
  echo "  7. render_report.py"
  echo "  8. stop_service.sh"
  echo "  9. render_report.py"
  echo "  10. show_state.sh"
  cat <<EOF

Key parameters:
  NODE=$NODE
  IMAGE=$IMAGE
  CONTAINER=$CONTAINER
  CONTAINER_PREFIX=$CONTAINER_PREFIX
  MODEL_NAME=$MODEL_NAME
  MODEL_SHORT=$MODEL_SHORT
  HOST_MODEL_PATH=$HOST_MODEL_PATH
  CONTAINER_MODEL_PATH=$CONTAINER_MODEL_PATH
  SERVER_SCRIPT=$SERVER_SCRIPT
  SERVER_SCRIPT_CONTAINER=$(resolve_server_script_for_container "$SERVER_SCRIPT")
  PORT=$PORT
  TP=$TP
  GPU_RANGE=$GPU_RANGE
  TEST_MODE=$TEST_MODE
  INPUT_LENS=$INPUT_LENS
  INPUT_LEN=$INPUT_LEN
  OUTPUT_LEN=$OUTPUT_LEN
  CONCURRENCIES=$CONCURRENCIES
  NUM_PROMPTS_MULT=$NUM_PROMPTS_MULT
  PERCENTILES=$PERCENTILES
  CACHE_HIT_RATES=$CACHE_HIT_RATES
  BATCHES=$BATCHES
  CONCURRENCY_MULTIPLIER=$CONCURRENCY_MULTIPLIER
  PC_HIT_TARGET=$PC_HIT_TARGET
  WARMUP_CACHE_HIT_RATES=$WARMUP_CACHE_HIT_RATES
  WARMUP_CONCURRENCY_MULTIPLIER=$WARMUP_CONCURRENCY_MULTIPLIER
  PC_HIT_TOLERANCE=$PC_HIT_TOLERANCE
  PC_HIT_TIMEOUT=$PC_HIT_TIMEOUT
  PC_HIT_INTERVAL=$PC_HIT_INTERVAL
  PCHIT_BENCHMARK_MODE=$PCHIT_BENCHMARK_MODE
  TTFT_SLA_MS=$TTFT_SLA_MS
  TPOT_SLA_MS=$TPOT_SLA_MS
  SLA_STAT=$SLA_STAT
  PREFIX_WARMUP_REQUESTS=$PREFIX_WARMUP_REQUESTS
  CASE_WARMUP_REPEATS=$CASE_WARMUP_REPEATS
  TIMEOUT=$TIMEOUT
  SKILL_USER=$SKILL_USER
  USER_ABBR=$USER_ABBR
  HOST_HOME_ROOT=$HOST_HOME_ROOT
  SKILL_HOST_ROOT=$SKILL_HOST_ROOT
  SKILL_CONTAINER_ROOT=$SKILL_CONTAINER_ROOT
  OUTPUT_HOST_ROOT=$OUTPUT_HOST_ROOT
  OUTPUT_CONTAINER_ROOT=$OUTPUT_CONTAINER_ROOT
  REPORT_DIR=$REPORT_DIR
EOF
  exit 0
fi

ENSURE_WORKSPACE_CMD=(
  bash "$SCRIPT_DIR/ensure_workspace.sh"
  --node "$NODE"
  --user "$SKILL_USER"
  --abbr "$USER_ABBR"
  --home-root "$HOME_ROOT"
  --host-home-root "$HOST_HOME_ROOT"
  --skill-host-root "$SKILL_HOST_ROOT"
  --output-host-root "$OUTPUT_HOST_ROOT"
  --output-container-root "$OUTPUT_CONTAINER_ROOT"
  --container-prefix "$CONTAINER_PREFIX"
)
if [[ "$ASSUME_YES" == "1" ]]; then
  ENSURE_WORKSPACE_CMD+=(--assume-yes)
fi
run_step_capture "ensure_workspace" "$TMP_DIR/workspace.out" "${ENSURE_WORKSPACE_CMD[@]}"

run_step_capture "preflight" "$TMP_DIR/preflight.out" \
  bash "$SCRIPT_DIR/preflight_node.sh" \
    --node "$NODE" \
    --image "$IMAGE" \
    --ports "$PORT" \
    --host-model-paths "$HOST_MODEL_PATH" \
    --container-names "$CONTAINER"

confirm_or_exit "This will create a container and occupy GPU/port resources."

run_step_capture "create_container" "$TMP_DIR/create.out" \
  env IMAGE_PREFIX_FALLBACK="$ALLOW_IMAGE_PREFIX_FALLBACK" bash "$SCRIPT_DIR/create_container.sh" \
    --node "$NODE" \
    --image "$IMAGE" \
    --model-short "$MODEL_SHORT" \
    --user "$SKILL_USER" \
    --abbr "$USER_ABBR" \
    --home-root "$HOME_ROOT" \
    --date "$DATE_PART" \
    --image-prefix "$IMAGE_PREFIX" \
    --container-prefix "$CONTAINER_PREFIX" \
    --host-home-root "$HOST_HOME_ROOT" \
    --name "$CONTAINER"

run_step_capture "start_vllm_service" "$TMP_DIR/start.out" \
  env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" \
    OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" \
    OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" \
    bash "$SCRIPT_DIR/start_vllm_service.sh" \
      --node "$NODE" \
      --container "$CONTAINER" \
      --user "$SKILL_USER" \
      --abbr "$USER_ABBR" \
      --home-root "$HOME_ROOT" \
      --host-home-root "$HOST_HOME_ROOT" \
      --skill-host-root "$SKILL_HOST_ROOT" \
      --output-host-root "$OUTPUT_HOST_ROOT" \
      --output-container-root "$OUTPUT_CONTAINER_ROOT" \
      --model-name "$MODEL_NAME" \
      --model-short "$MODEL_SHORT" \
      --container-model-path "$CONTAINER_MODEL_PATH" \
      --host-model-path "$HOST_MODEL_PATH" \
      --server-script "$SERVER_SCRIPT" \
      --image "$IMAGE" \
      --test-mode "$TEST_MODE" \
      --port "$PORT" \
      --tp "$TP" \
      --gpu-range "$GPU_RANGE"

WORK_DIR_CONTAINER="$(extract_value WORK_DIR_CONTAINER "$TMP_DIR/start.out")"
WORK_DIR_HOST="$(extract_value WORK_DIR_HOST "$TMP_DIR/start.out")"
LOG_CONTAINER="$(extract_value LOG_CONTAINER "$TMP_DIR/start.out")"
STATE_CONTAINER="$(extract_value STATE_CONTAINER "$TMP_DIR/start.out")"
STATE_HOST="$(extract_value STATE_HOST "$TMP_DIR/start.out")"

for var in WORK_DIR_CONTAINER WORK_DIR_HOST LOG_CONTAINER STATE_CONTAINER STATE_HOST; do
  [[ -n "${!var}" ]] || { echo "start_vllm_service did not output required field: ${var}" >&2; exit 1; }
done

python3 "$SCRIPT_DIR/update_state.py" --state "$STATE_HOST" \
  --set "ops.version=$OPS_VERSION" \
  --set "ops.entrypoint=$0" \
  --set "ops.script_dir=$SCRIPT_DIR" \
  --set "timing.readiness_timeout_seconds=$TIMEOUT" \
  --set "test.mode=$TEST_MODE" \
  --set "test.params.input_lens=$INPUT_LENS" \
  --set "test.params.input_len=$INPUT_LEN" \
  --set "test.params.output_len=$OUTPUT_LEN" \
  --set "test.params.concurrencies=$CONCURRENCIES" \
  --set "test.params.num_prompts_mult=$NUM_PROMPTS_MULT" \
  --set "test.params.percentiles=$PERCENTILES" \
  --set "test.params.request_rate=$REQUEST_RATE" \
  --set "test.params.cache_hit_rates=$CACHE_HIT_RATES" \
  --set "test.params.batches=$BATCHES" \
  --set "test.params.concurrency_multiplier=$CONCURRENCY_MULTIPLIER" \
  --set "pchit.warmup.target_pct=$PC_HIT_TARGET" \
  --set "pchit.warmup.cache_hit_rates=$WARMUP_CACHE_HIT_RATES" \
  --set "pchit.warmup.concurrency_multiplier=$WARMUP_CONCURRENCY_MULTIPLIER" \
  --set "pchit.warmup.tolerance_pct=$PC_HIT_TOLERANCE" \
  --set "pchit.warmup.timeout_seconds=$PC_HIT_TIMEOUT" \
  --set "pchit.warmup.interval_seconds=$PC_HIT_INTERVAL" \
  --set "pchit.benchmark.mode=$PCHIT_BENCHMARK_MODE" \
  --set "pchit.benchmark.target_pct=$PC_HIT_TARGET" \
  --set "pchit.benchmark.ttft_sla_ms=$TTFT_SLA_MS" \
  --set "pchit.benchmark.tpot_sla_ms=$TPOT_SLA_MS" \
  --set "pchit.benchmark.sla_stat=$SLA_STAT" \
  --set "pchit.benchmark.prefix_warmup_requests=$PREFIX_WARMUP_REQUESTS" \
  --set "pchit.benchmark.case_warmup_repeats=$CASE_WARMUP_REPEATS" || true

run_step_capture "wait_vllm_ready" "$TMP_DIR/wait.out" \
  env VERBOSE=1 SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" \
    bash "$SCRIPT_DIR/wait_vllm_ready.sh" \
      --node "$NODE" \
      --container "$CONTAINER" \
      --port "$PORT" \
      --log "$LOG_CONTAINER" \
      --model-path "$CONTAINER_MODEL_PATH" \
      --state "$STATE_CONTAINER" \
      --timeout "$TIMEOUT" \
      --interval "$INTERVAL"

SERVED_MODEL_ID="$(extract_value SERVED_MODEL_ID "$TMP_DIR/wait.out")"
[[ -n "$SERVED_MODEL_ID" ]] || { echo "wait_vllm_ready did not output SERVED_MODEL_ID" >&2; exit 1; }

if [[ "$TEST_MODE" == "pchit" ]]; then
  run_step_capture "run_bench" "$TMP_DIR/bench.out" \
    env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" \
      OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" \
      OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" \
      IMAGE_NAME="$IMAGE" \
      INPUT_LEN="$INPUT_LEN" \
      OUTPUT_LEN="$OUTPUT_LEN" \
      CACHE_HIT_RATES="$CACHE_HIT_RATES" \
      BATCHES="$BATCHES" \
      CONCURRENCY_MULTIPLIER="$CONCURRENCY_MULTIPLIER" \
      PCHIT_TARGET_PCT="$PC_HIT_TARGET" \
      PCHIT_BENCHMARK_MODE="$PCHIT_BENCHMARK_MODE" \
      TTFT_SLA_MS="$TTFT_SLA_MS" \
      TPOT_SLA_MS="$TPOT_SLA_MS" \
      SLA_STAT="$SLA_STAT" \
      PREFIX_WARMUP_REQUESTS="$PREFIX_WARMUP_REQUESTS" \
      CASE_WARMUP_REPEATS="$CASE_WARMUP_REPEATS" \
      REQUEST_RATE="$REQUEST_RATE" \
      bash "$SCRIPT_DIR/run_bench.sh" \
        --node "$NODE" \
        --container "$CONTAINER" \
        --test-mode "$TEST_MODE" \
        --served-model-id "$SERVED_MODEL_ID" \
        --port "$PORT" \
        --tp "$TP" \
        --work-dir "$WORK_DIR_CONTAINER" \
        --state "$STATE_CONTAINER" \
        --user "$SKILL_USER" \
        --abbr "$USER_ABBR" \
        --host-home-root "$HOST_HOME_ROOT" \
        --skill-host-root "$SKILL_HOST_ROOT" \
        --output-host-root "$OUTPUT_HOST_ROOT" \
        --output-container-root "$OUTPUT_CONTAINER_ROOT" \
        --container-prefix "$CONTAINER_PREFIX"
else
  run_step_capture "run_bench" "$TMP_DIR/bench.out" \
    env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" \
      OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" \
      OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" \
      IMAGE_NAME="$IMAGE" \
      INPUT_LENS="$INPUT_LENS" \
      OUTPUT_LEN="$OUTPUT_LEN" \
      CONCURRENCIES="$CONCURRENCIES" \
      NUM_PROMPTS_MULT="$NUM_PROMPTS_MULT" \
      PERCENTILES="$PERCENTILES" \
      REQUEST_RATE="$REQUEST_RATE" \
      bash "$SCRIPT_DIR/run_bench.sh" \
        --node "$NODE" \
        --container "$CONTAINER" \
        --test-mode "$TEST_MODE" \
        --served-model-id "$SERVED_MODEL_ID" \
        --port "$PORT" \
        --tp "$TP" \
        --work-dir "$WORK_DIR_CONTAINER" \
        --state "$STATE_CONTAINER" \
        --user "$SKILL_USER" \
        --abbr "$USER_ABBR" \
        --host-home-root "$HOST_HOME_ROOT" \
        --skill-host-root "$SKILL_HOST_ROOT" \
        --output-host-root "$OUTPUT_HOST_ROOT" \
        --output-container-root "$OUTPUT_CONTAINER_ROOT" \
        --container-prefix "$CONTAINER_PREFIX"
fi

CSV_HOST="$(extract_value CSV_HOST "$TMP_DIR/bench.out")"
[[ -n "$CSV_HOST" ]] || CSV_HOST="${WORK_DIR_HOST}/csvs/${TEST_MODE}/all.csv"

echo "== render_report_before_stop =="
REPORT_BEFORE_RC=0
set +e
OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" python3 "$SCRIPT_DIR/render_report.py" \
  --run-id "$RUN_ID" \
  --state "$STATE_HOST" \
  --csv "$CSV_HOST" \
  --report-dir "$REPORT_DIR" | tee "$TMP_DIR/report_before_stop.out"
REPORT_BEFORE_RC=${PIPESTATUS[0]}
set -e
if [[ "$REPORT_BEFORE_RC" != "0" ]]; then
  echo "WARN: report before stop failed; continue to stop service." >&2
fi

echo "== stop_service =="
STOP_RC=0
set +e
SKILL_HOST_ROOT="$SKILL_HOST_ROOT" \
  OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" \
  OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" \
  bash "$SCRIPT_DIR/stop_service.sh" \
    --node "$NODE" \
    --container "$CONTAINER" \
    --port "$PORT" \
    --state "$STATE_HOST" \
    --user "$SKILL_USER" \
    --abbr "$USER_ABBR" \
    --host-home-root "$HOST_HOME_ROOT" \
    --skill-host-root "$SKILL_HOST_ROOT" \
    --output-host-root "$OUTPUT_HOST_ROOT" \
    --output-container-root "$OUTPUT_CONTAINER_ROOT" \
    --container-prefix "$CONTAINER_PREFIX" 2>&1 | tee "$TMP_DIR/stop.out"
STOP_RC=${PIPESTATUS[0]}
set -e

if [[ "$STOP_RC" != "0" ]]; then
  python3 "$SCRIPT_DIR/update_state.py" --state "$STATE_HOST" \
    --set "status=STOP_FAILED" \
    --set "failure.reason=stop_service_failed" \
    --set "failure.exit_code=$STOP_RC" || true
  echo "STOP_FAILED: stop_service.sh returned $STOP_RC; no manual docker/ssh fallback executed." >&2
  echo "Use ops recovery:" >&2
  echo "bash $SCRIPT_DIR/recover_single_task.sh --state $STATE_HOST --node $NODE --container $CONTAINER --port $PORT --report-dir $REPORT_DIR" >&2
fi

echo "== render_report_final =="
REPORT_FINAL_RC=0
set +e
OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" python3 "$SCRIPT_DIR/render_report.py" \
  --run-id "$RUN_ID" \
  --state "$STATE_HOST" \
  --csv "$CSV_HOST" \
  --report-dir "$REPORT_DIR" | tee "$TMP_DIR/report_final.out"
REPORT_FINAL_RC=${PIPESTATUS[0]}
set -e
if [[ "$REPORT_FINAL_RC" != "0" ]]; then
  echo "WARN: final report generation failed." >&2
fi

echo "== show_state =="
bash "$SCRIPT_DIR/show_state.sh" --state "$STATE_HOST" \
  --user "$SKILL_USER" \
  --abbr "$USER_ABBR" \
  --host-home-root "$HOST_HOME_ROOT" \
  --skill-host-root "$SKILL_HOST_ROOT" \
  --output-host-root "$OUTPUT_HOST_ROOT" \
  --output-container-root "$OUTPUT_CONTAINER_ROOT" \
  --container-prefix "$CONTAINER_PREFIX" || true

if [[ "$STOP_RC" != "0" ]]; then
  exit "$STOP_RC"
fi

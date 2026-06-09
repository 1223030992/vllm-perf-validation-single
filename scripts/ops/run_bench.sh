#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  run_bench.sh --node NODE --container NAME --test-mode MODE --served-model-id ID \
    --port PORT --tp TP --work-dir WORK_DIR [--state STATE]

选项:
  --dry-run

透传给 client 脚本的环境变量:
  WORK_DIR TEST_MODE IMAGE_NAME INPUT_LENS OUTPUT_LEN CONCURRENCIES
  NUM_PROMPTS_MULT REQUEST_RATE PERCENTILES CACHE_HIT_RATES BATCHES PAIRS
  INPUT_LEN OUTPUT_LENS CONCURRENCY_MULTIPLIER PCHIT_TARGET_PCT
  PCHIT_BENCHMARK_MODE TTFT_SLA_MS TPOT_SLA_MS SLA_STAT
  PREFIX_WARMUP_REQUESTS CASE_WARMUP_REPEATS

说明:
  本脚本强制在容器内使用 bash -ic 执行 benchmark，避免 DTK/HIP 环境未加载导致缺库。
  不要直接调用 scripts/client-scripts/*.sh 作为主流程入口。
USAGE
}

quote_sh() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

to_host_path() {
  local path="$1"
  local output_container_root="${OUTPUT_CONTAINER_ROOT:-/mnt/skilltest/vllm-perf-validation-single}"
  local output_host_root="$OUTPUT_HOST_ROOT"
  if [[ "$path" == "$output_container_root"* ]]; then
    printf '%s%s\n' "$output_host_root" "${path#$output_container_root}"
  else
    printf '%s\n' "$path"
  fi
}

to_container_path() {
  local path="$1"
  local output_container_root="${OUTPUT_CONTAINER_ROOT:-/mnt/skilltest/vllm-perf-validation-single}"
  local output_host_root="$OUTPUT_HOST_ROOT"
  if [[ "$path" == "$output_host_root"* ]]; then
    printf '%s%s\n' "$output_container_root" "${path#$output_host_root}"
  else
    printf '%s\n' "$path"
  fi
}

state_get() {
  local state_file="$1"
  local dotted="$2"
  if [[ ! -f "$state_file" ]]; then
    return 0
  fi
  python3 - "$state_file" "$dotted" <<'PY'
import json
import sys

state_file, dotted = sys.argv[1], sys.argv[2]
with open(state_file, "r", encoding="utf-8-sig") as f:
    data = json.load(f)
cur = data
for key in dotted.split("."):
    if not isinstance(cur, dict) or key not in cur:
        print("")
        sys.exit(0)
    cur = cur[key]
print(cur if cur is not None else "")
PY
}

run_in_container() {
  local script="$1"
  local docker_cmd
  docker_cmd="docker exec -i -w $(quote_sh "$SKILL_CONTAINER_ROOT") $(quote_sh "$CONTAINER") bash -ic 'tmp=/tmp/vllm_ops_bench_\$\$.sh; cat > \"\$tmp\"; bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc'"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "即将在容器内执行 benchmark:"
    printf 'ssh %q %q\n' "$NODE" "$docker_cmd"
    echo "--- container script ---"
    printf '%s\n' "$script"
    return 0
  fi
  printf '%s\n' "$script" | ssh "$NODE" "$docker_cmd"
}

NODE=""
CONTAINER=""
TEST_MODE=""
SERVED_MODEL_ID=""
PORT=""
TP=""
WORK_DIR=""
STATE=""
DRY_RUN="${DRY_RUN:-0}"
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
CONTAINER_PREFIX=""

while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then
    shift 2
    continue
  fi
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --test-mode) TEST_MODE="$2"; shift 2 ;;
    --served-model-id) SERVED_MODEL_ID="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --tp) TP="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

for var in NODE CONTAINER TEST_MODE SERVED_MODEL_ID PORT TP WORK_DIR; do
  [[ -n "${!var}" ]] || { echo "缺少参数: ${var}" >&2; exit 2; }
done
resolve_runtime_config
if [[ -z "$STATE" ]]; then
  STATE="${WORK_DIR}/state.json"
fi

WORK_DIR="$(to_container_path "$WORK_DIR")"
STATE="$(to_container_path "$STATE")"

case "$TEST_MODE" in
  full) CLIENT_SCRIPT="scripts/client-scripts/run_perf_test-full.sh" ;;
  pchit) CLIENT_SCRIPT="scripts/client-scripts/prefix_cache_benchmark.py" ;;
  engin) CLIENT_SCRIPT="scripts/client-scripts/run_perf_test-engin.sh" ;;
  custom) CLIENT_SCRIPT="scripts/client-scripts/run_perf_test-custom.sh" ;;
  *) echo "未知测试模式: $TEST_MODE" >&2; exit 2 ;;
esac

CSV_FILE="${WORK_DIR}/csvs/${TEST_MODE}/all.csv"
PCHIT_JSON_FILE="${WORK_DIR}/csvs/${TEST_MODE}/prefix_cache_benchmark.json"
CSV_FILE_HOST="$(to_host_path "$CSV_FILE")"
PCHIT_JSON_FILE_HOST="$(to_host_path "$PCHIT_JSON_FILE")"
WORK_DIR_HOST="$(to_host_path "$WORK_DIR")"
STATE_HOST="$(to_host_path "$STATE")"

if [[ -f "$STATE_HOST" ]]; then
  INPUT_LENS="${INPUT_LENS:-$(state_get "$STATE_HOST" test.params.input_lens)}"
  INPUT_LEN="${INPUT_LEN:-$(state_get "$STATE_HOST" test.params.input_len)}"
  OUTPUT_LEN="${OUTPUT_LEN:-$(state_get "$STATE_HOST" test.params.output_len)}"
  CONCURRENCIES="${CONCURRENCIES:-$(state_get "$STATE_HOST" test.params.concurrencies)}"
  NUM_PROMPTS_MULT="${NUM_PROMPTS_MULT:-$(state_get "$STATE_HOST" test.params.num_prompts_mult)}"
  PERCENTILES="${PERCENTILES:-$(state_get "$STATE_HOST" test.params.percentiles)}"
  REQUEST_RATE="${REQUEST_RATE:-$(state_get "$STATE_HOST" test.params.request_rate)}"
  CACHE_HIT_RATES="${CACHE_HIT_RATES:-$(state_get "$STATE_HOST" test.params.cache_hit_rates)}"
  BATCHES="${BATCHES:-$(state_get "$STATE_HOST" test.params.batches)}"
  CONCURRENCY_MULTIPLIER="${CONCURRENCY_MULTIPLIER:-$(state_get "$STATE_HOST" test.params.concurrency_multiplier)}"
  PCHIT_TARGET_PCT="${PCHIT_TARGET_PCT:-$(state_get "$STATE_HOST" pchit.benchmark.target_pct)}"
  PCHIT_TARGET_PCT="${PCHIT_TARGET_PCT:-$(state_get "$STATE_HOST" pchit.warmup.target_pct)}"
  PCHIT_BENCHMARK_MODE="${PCHIT_BENCHMARK_MODE:-$(state_get "$STATE_HOST" pchit.benchmark.mode)}"
  TTFT_SLA_MS="${TTFT_SLA_MS:-$(state_get "$STATE_HOST" pchit.benchmark.ttft_sla_ms)}"
  TPOT_SLA_MS="${TPOT_SLA_MS:-$(state_get "$STATE_HOST" pchit.benchmark.tpot_sla_ms)}"
  SLA_STAT="${SLA_STAT:-$(state_get "$STATE_HOST" pchit.benchmark.sla_stat)}"
  PREFIX_WARMUP_REQUESTS="${PREFIX_WARMUP_REQUESTS:-$(state_get "$STATE_HOST" pchit.benchmark.prefix_warmup_requests)}"
  CASE_WARMUP_REPEATS="${CASE_WARMUP_REPEATS:-$(state_get "$STATE_HOST" pchit.benchmark.case_warmup_repeats)}"
fi

env_exports=""
for name in IMAGE_NAME INPUT_LENS OUTPUT_LEN CONCURRENCIES NUM_PROMPTS_MULT REQUEST_RATE PERCENTILES CACHE_HIT_RATES BATCHES PAIRS INPUT_LEN OUTPUT_LENS CONCURRENCY_MULTIPLIER PCHIT_TARGET_PCT PCHIT_BENCHMARK_MODE TTFT_SLA_MS TPOT_SLA_MS SLA_STAT PREFIX_WARMUP_REQUESTS CASE_WARMUP_REPEATS; do
  if [[ -n "${!name-}" ]]; then
    env_exports+="export ${name}=$(quote_sh "${!name}")"$'\n'
  fi
done

remote_script=$(cat <<EOF
set -euo pipefail
cd $(quote_sh "$SKILL_CONTAINER_ROOT")
WORK_DIR=$(quote_sh "$WORK_DIR")
WORK_DIR_HOST=$(quote_sh "$WORK_DIR_HOST")
STATE=$(quote_sh "$STATE")
STATE_HOST=$(quote_sh "$STATE_HOST")
CSV_FILE=$(quote_sh "$CSV_FILE")
CSV_FILE_HOST=$(quote_sh "$CSV_FILE_HOST")
PCHIT_JSON_FILE=$(quote_sh "$PCHIT_JSON_FILE")
PCHIT_JSON_FILE_HOST=$(quote_sh "$PCHIT_JSON_FILE_HOST")
ENV_CHECK_LOG="\$WORK_DIR/logs/bench-env-check.log"

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

mkdir -p "\$WORK_DIR/logs"

export TEST_MODE=$(quote_sh "$TEST_MODE")
export SERVED_MODEL_ID=$(quote_sh "$SERVED_MODEL_ID")
export BENCH_MODEL_ID="\${BENCH_MODEL_ID:-$SERVED_MODEL_ID}"
export MODEL_PATH=$(quote_sh "$SERVED_MODEL_ID")
export PORT=$(quote_sh "$PORT")
export TP=$(quote_sh "$TP")
export WORK_DIR="\$WORK_DIR"
${env_exports}

python3 $(quote_sh "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py") --state "\$STATE" \
  --set "status=BENCH_ENV_CHECKING" \
  --set "test.mode=$(printf '%s' "$TEST_MODE")" \
  --set "test.params.input_lens=\${INPUT_LENS:-}" \
  --set "test.params.input_len=\${INPUT_LEN:-}" \
  --set "test.params.output_len=\${OUTPUT_LEN:-}" \
  --set "test.params.concurrencies=\${CONCURRENCIES:-}" \
  --set "test.params.num_prompts_mult=\${NUM_PROMPTS_MULT:-}" \
  --set "test.params.percentiles=\${PERCENTILES:-}" \
  --set "test.params.request_rate=\${REQUEST_RATE:-}" \
  --set "test.params.cache_hit_rates=\${CACHE_HIT_RATES:-}" \
  --set "test.params.batches=\${BATCHES:-}" \
  --set "test.params.concurrency_multiplier=\${CONCURRENCY_MULTIPLIER:-}" \
  --set "pchit.benchmark.mode=\${PCHIT_BENCHMARK_MODE:-fixed}" \
  --set "pchit.benchmark.target_pct=\${PCHIT_TARGET_PCT:-}" \
  --set "pchit.benchmark.ttft_sla_ms=\${TTFT_SLA_MS:-5000}" \
  --set "pchit.benchmark.tpot_sla_ms=\${TPOT_SLA_MS:-50}" \
  --set "pchit.benchmark.sla_stat=\${SLA_STAT:-mean}" \
  --set "pchit.benchmark.prefix_warmup_requests=\${PREFIX_WARMUP_REQUESTS:-1}" \
  --set "pchit.benchmark.case_warmup_repeats=\${CASE_WARMUP_REPEATS:-0}" \
  --set "model.served_model_id=$(printf '%s' "$SERVED_MODEL_ID")" \
  --set "model.bench_model_id=\$BENCH_MODEL_ID" \
  --set "paths.work_dir_host=\$WORK_DIR_HOST" \
  --set "paths.csv_file=\$CSV_FILE" \
  --set "paths.csv_file_container=\$CSV_FILE" \
  --set "paths.csv_file_host=\$CSV_FILE_HOST" \
  --set "paths.pchit_json_file=\$PCHIT_JSON_FILE" \
  --set "paths.pchit_json_file_host=\$PCHIT_JSON_FILE_HOST"

if [[ "\$TEST_MODE" == "pchit" ]]; then
  if ! python3 - <<'PY' > "\$ENV_CHECK_LOG" 2>&1
import aiohttp  # noqa: F401
PY
  then
    python3 $(quote_sh "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py") --state "\$STATE" \
      --set "status=BENCH_FAILED" \
      --set "test.status=FAILED" \
      --set "failure.reason=bench_env_missing_aiohttp" \
      --set "failure.detail=python_import_aiohttp_failed" \
      --set "paths.bench_env_check_log=\$ENV_CHECK_LOG"
    echo "BENCH_ENV_FAILED: pchit benchmark requires aiohttp in the container." >&2
    cat "\$ENV_CHECK_LOG" >&2 || true
    exit 1
  fi
else
  if ! python3 - <<'PY' > "\$ENV_CHECK_LOG" 2>&1
import torch  # noqa: F401
PY
  then
    python3 $(quote_sh "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py") --state "\$STATE" \
      --set "status=BENCH_FAILED" \
      --set "test.status=FAILED" \
      --set "failure.reason=bench_env_missing_dtk_library" \
      --set "failure.detail=python_import_torch_failed" \
      --set "paths.bench_env_check_log=\$ENV_CHECK_LOG"
    echo "BENCH_ENV_FAILED: benchmark environment did not load torch/DTK correctly." >&2
    cat "\$ENV_CHECK_LOG" >&2 || true
    exit 1
  fi

  if ! vllm --version >> "\$ENV_CHECK_LOG" 2>&1; then
    python3 $(quote_sh "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py") --state "\$STATE" \
      --set "status=BENCH_FAILED" \
      --set "test.status=FAILED" \
      --set "failure.reason=bench_env_missing_dtk_library" \
      --set "failure.detail=vllm_version_failed" \
      --set "paths.bench_env_check_log=\$ENV_CHECK_LOG"
    echo "BENCH_ENV_FAILED: vllm command is unavailable or missing runtime libraries." >&2
    cat "\$ENV_CHECK_LOG" >&2 || true
    exit 1
  fi
fi

python3 $(quote_sh "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py") --state "\$STATE" \
  --set "status=BENCH_RUNNING" \
  --set "paths.bench_env_check_log=\$ENV_CHECK_LOG"

bench_ok=0
if [[ "\$TEST_MODE" == "pchit" ]]; then
  mkdir -p "\$(dirname "\$CSV_FILE")"
  concurrency_list="\$(printf '%s' "\${BATCHES:-1,2,3,4,5,6,7,8}" | tr ',' ' ')"
  if python3 scripts/client-scripts/prefix_cache_benchmark.py \
    --mode "\${PCHIT_BENCHMARK_MODE:-fixed}" \
    --base-url "http://127.0.0.1:\${PORT}" \
    --model "\$BENCH_MODEL_ID" \
    --input-lengths "\${INPUT_LEN:?missing INPUT_LEN}" \
    --output-length "\${OUTPUT_LEN:?missing OUTPUT_LEN}" \
    --prefix-cache-hit "\${PCHIT_TARGET_PCT:?missing PCHIT_TARGET_PCT}" \
    --concurrency-list \$concurrency_list \
    --request-multiplier "\${CONCURRENCY_MULTIPLIER:-1}" \
    --request-rate "\${REQUEST_RATE:-0}" \
    --ttft-sla-ms "\${TTFT_SLA_MS:-5000}" \
    --tpot-sla-ms "\${TPOT_SLA_MS:-50}" \
    --sla-stat "\${SLA_STAT:-mean}" \
    --prefix-warmup-requests "\${PREFIX_WARMUP_REQUESTS:-1}" \
    --case-warmup-repeats "\${CASE_WARMUP_REPEATS:-0}" \
    --save-path "\$(dirname "\$CSV_FILE")" \
    --csv-file "\$CSV_FILE" \
    --json-file "\$PCHIT_JSON_FILE"; then
    bench_ok=1
  else
    bench_ok=0
  fi
else
  if bash $(quote_sh "$CLIENT_SCRIPT") "\$BENCH_MODEL_ID" $(quote_sh "$PORT") $(quote_sh "$TP"); then
    bench_ok=1
  else
    bench_ok=0
  fi
fi

if [[ "\$bench_ok" == "1" ]]; then
  if [[ ! -s "\$CSV_FILE" ]]; then
    python3 $(quote_sh "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py") --state "\$STATE" \
      --set "status=BENCH_FAILED" \
      --set "test.status=FAILED" \
      --set "failure.reason=bench_csv_missing" \
      --set "paths.csv_file=\$CSV_FILE" \
      --set "paths.csv_file_container=\$CSV_FILE" \
      --set "paths.csv_file_host=\$CSV_FILE_HOST" \
      --set "paths.pchit_json_file=\$PCHIT_JSON_FILE" \
      --set "paths.pchit_json_file_host=\$PCHIT_JSON_FILE_HOST"
    echo "BENCH_FAILED: bench_csv_missing: \$CSV_FILE" >&2
    exit 1
  fi
  python3 $(quote_sh "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py") --state "\$STATE" \
    --set "status=BENCH_DONE" \
    --set "test.status=COMPLETED" \
    --set "paths.csv_file=\$CSV_FILE" \
    --set "paths.csv_file_container=\$CSV_FILE" \
    --set "paths.csv_file_host=\$CSV_FILE_HOST" \
    --set "paths.pchit_json_file=\$PCHIT_JSON_FILE" \
    --set "paths.pchit_json_file_host=\$PCHIT_JSON_FILE_HOST"
  echo "CSV_CONTAINER=\$CSV_FILE"
  echo "CSV_HOST=\$CSV_FILE_HOST"
  if [[ "\$TEST_MODE" == "pchit" ]]; then
    echo "PCHIT_JSON_CONTAINER=\$PCHIT_JSON_FILE"
    echo "PCHIT_JSON_HOST=\$PCHIT_JSON_FILE_HOST"
  fi
else
  rc=1
  python3 $(quote_sh "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py") --state "\$STATE" \
    --set "status=BENCH_FAILED" \
    --set "test.status=FAILED" \
    --set "failure.reason=bench_script_failed" \
    --set "failure.exit_code=\$rc" \
    --set "paths.csv_file=\$CSV_FILE" \
    --set "paths.csv_file_container=\$CSV_FILE" \
    --set "paths.csv_file_host=\$CSV_FILE_HOST" \
    --set "paths.pchit_json_file=\$PCHIT_JSON_FILE" \
    --set "paths.pchit_json_file_host=\$PCHIT_JSON_FILE_HOST"
  exit "\$rc"
fi
EOF
)

run_in_container "$remote_script"

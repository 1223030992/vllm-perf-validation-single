#!/usr/bin/env bash

SKILL_NAME="${SKILL_NAME:-vllm-perf-validation-single}"
SKILL_CONTAINER_ROOT="${SKILL_CONTAINER_ROOT:-/mnt/.claude/skills/${SKILL_NAME}}"
OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-/mnt/skilltest/${SKILL_NAME}}"

runtime_config_parse_common_arg() {
  case "$1" in
    --user) SKILL_USER="$2"; return 0 ;;
    --abbr) USER_ABBR="$2"; return 0 ;;
    --home-root) HOME_ROOT="$2"; return 0 ;;
    --host-home-root) HOST_HOME_ROOT="$2"; return 0 ;;
    --skill-host-root) SKILL_HOST_ROOT="$2"; return 0 ;;
    --output-host-root) OUTPUT_HOST_ROOT="$2"; return 0 ;;
    --output-container-root) OUTPUT_CONTAINER_ROOT="$2"; return 0 ;;
    --container-prefix) CONTAINER_PREFIX="$2"; return 0 ;;
  esac
  return 1
}

infer_user_from_skill_root() {
  local root="${1%/}"
  case "$root" in
    /public/home/*/.claude/skills/"$SKILL_NAME"|/public2/home/*/.claude/skills/"$SKILL_NAME")
      local rest="${root#*/home/}"
      printf '%s\n' "${rest%%/*}"
      return 0
      ;;
  esac
  return 1
}

normalize_home_root() {
  local root="${1%/}"
  if [[ "$root" == "/public2/home" ]]; then
    printf '%s\n' "/public/home"
  else
    printf '%s\n' "$root"
  fi
}

validate_abs_path() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" || "$value" != /* ]]; then
    echo "$name must be an absolute path: $value" >&2
    return 2
  fi
}

validate_container_prefix() {
  local prefix="$1"
  if ! [[ "$prefix" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
    echo "CONTAINER_PREFIX must use lowercase letters, digits, and hyphens: $prefix" >&2
    return 2
  fi
}

resolve_runtime_config() {
  local skill_root="${SKILL_ROOT:-}"
  HOME_ROOT="${HOME_ROOT:-/public/home}"
  HOME_ROOT="$(normalize_home_root "$HOME_ROOT")"

  if [[ -z "${SKILL_USER:-}" && -n "$skill_root" ]]; then
    SKILL_USER="$(infer_user_from_skill_root "$skill_root" || true)"
  fi
  if [[ -z "${SKILL_USER:-}" ]]; then
    echo "missing runtime user; pass --user <linux_user>" >&2
    return 2
  fi

  USER_ABBR="${USER_ABBR:-$SKILL_USER}"
  HOST_HOME_ROOT="${HOST_HOME_ROOT:-${HOME_ROOT}/${SKILL_USER}}"
  SKILL_HOST_ROOT="${SKILL_HOST_ROOT:-${HOST_HOME_ROOT}/.claude/skills/${SKILL_NAME}}"
  OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-${HOST_HOME_ROOT}/skilltest/${SKILL_NAME}}"
  CONTAINER_PREFIX="${CONTAINER_PREFIX:-${USER_ABBR}-agent-test}"

  HOST_HOME_ROOT="${HOST_HOME_ROOT%/}"
  SKILL_HOST_ROOT="${SKILL_HOST_ROOT%/}"
  OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT%/}"
  OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT%/}"
  SKILL_CONTAINER_ROOT="${SKILL_CONTAINER_ROOT%/}"

  validate_abs_path HOST_HOME_ROOT "$HOST_HOME_ROOT"
  validate_abs_path SKILL_HOST_ROOT "$SKILL_HOST_ROOT"
  validate_abs_path OUTPUT_HOST_ROOT "$OUTPUT_HOST_ROOT"
  validate_abs_path OUTPUT_CONTAINER_ROOT "$OUTPUT_CONTAINER_ROOT"
  validate_abs_path SKILL_CONTAINER_ROOT "$SKILL_CONTAINER_ROOT"
  validate_container_prefix "$CONTAINER_PREFIX"

  case "$OUTPUT_HOST_ROOT" in
    "$HOST_HOME_ROOT"|"$HOST_HOME_ROOT"/*) ;;
    *)
      echo "OUTPUT_HOST_ROOT must be under HOST_HOME_ROOT" >&2
      echo "HOST_HOME_ROOT=$HOST_HOME_ROOT" >&2
      echo "OUTPUT_HOST_ROOT=$OUTPUT_HOST_ROOT" >&2
      return 2
      ;;
  esac

  export SKILL_USER USER_ABBR HOME_ROOT HOST_HOME_ROOT SKILL_HOST_ROOT
  export SKILL_CONTAINER_ROOT OUTPUT_HOST_ROOT OUTPUT_CONTAINER_ROOT CONTAINER_PREFIX
}

print_runtime_config() {
  echo "SKILL_USER=$SKILL_USER"
  echo "USER_ABBR=$USER_ABBR"
  echo "HOST_HOME_ROOT=$HOST_HOME_ROOT"
  echo "SKILL_HOST_ROOT=$SKILL_HOST_ROOT"
  echo "SKILL_CONTAINER_ROOT=$SKILL_CONTAINER_ROOT"
  echo "OUTPUT_HOST_ROOT=$OUTPUT_HOST_ROOT"
  echo "OUTPUT_CONTAINER_ROOT=$OUTPUT_CONTAINER_ROOT"
  echo "CONTAINER_PREFIX=$CONTAINER_PREFIX"
}

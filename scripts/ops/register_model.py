#!/usr/bin/env python3
"""Register a model profile/example for the vLLM perf validation skill.

This script is intentionally local-only: it never connects to SSH, Docker, or GPUs.
It is Python 3.6 compatible because some target hosts only provide Python 3.6.
"""

import argparse
import os
import re
import shutil
from datetime import datetime
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parents[2]
PROFILES_DIR = SKILL_ROOT / "references" / "profiles"
EXAMPLES_DIR = SKILL_ROOT / "references" / "examples"
CONVENTIONS_FILE = SKILL_ROOT / "references" / "conventions.md"
SERVER_SCRIPTS_DIR = SKILL_ROOT / "scripts" / "server-scripts"


def infer_user_from_skill_root():
    root = SKILL_ROOT.as_posix().rstrip("/")
    for marker in ("/public/home/", "/public2/home/"):
        if marker in root:
            tail = root.split(marker, 1)[1]
            user = tail.split("/", 1)[0]
            if user:
                return user
    return os.environ.get("SKILL_USER") or os.environ.get("USER") or os.environ.get("LOGNAME") or "<user>"


DEFAULT_USER = infer_user_from_skill_root()
DEFAULT_ABBR = os.environ.get("USER_ABBR", DEFAULT_USER)
DEFAULT_HOME_ROOT = os.environ.get("HOME_ROOT", "/public/home").rstrip("/")
DEFAULT_HOST_HOME_ROOT = os.environ.get("HOST_HOME_ROOT", DEFAULT_HOME_ROOT + "/" + DEFAULT_USER).rstrip("/")
DEFAULT_SKILL_HOST_ROOT = os.environ.get(
    "SKILL_HOST_ROOT", DEFAULT_HOST_HOME_ROOT + "/.claude/skills/vllm-perf-validation-single"
).rstrip("/")
DEFAULT_OUTPUT_HOST_ROOT = os.environ.get(
    "OUTPUT_HOST_ROOT", DEFAULT_HOST_HOME_ROOT + "/skilltest/vllm-perf-validation-single"
).rstrip("/")
DEFAULT_SKILL_CONTAINER_ROOT = os.environ.get(
    "SKILL_CONTAINER_ROOT", "/mnt/.claude/skills/vllm-perf-validation-single"
).rstrip("/")
DEFAULT_OUTPUT_CONTAINER_ROOT = os.environ.get(
    "OUTPUT_CONTAINER_ROOT", "/mnt/skilltest/vllm-perf-validation-single"
).rstrip("/")
DEFAULT_CONTAINER_PREFIX = os.environ.get("CONTAINER_PREFIX", DEFAULT_ABBR + "-agent-test")
DEFAULT_OWNER = os.environ.get("SKILL_OWNER", DEFAULT_USER)


def normalize_name(name):
    return name.strip().strip("/")


def detect_precision_from_text(text):
    upper = text.upper()
    if "INT4" in upper or "W4A8" in upper or "W4A16" in upper:
        return "int4"
    if "W8A8" in upper or "INT8" in upper:
        return "int8"
    if "W8A16" in upper or "FP8" in upper:
        return "fp8"
    return None


def infer_precision(model_name, service_script, explicit_precision=None):
    """Return model/weight precision, not compute dtype."""
    if explicit_precision:
        return explicit_precision, False
    detected = detect_precision_from_text(model_name)
    if detected:
        return detected, False
    detected = detect_precision_from_text(Path(service_script).name)
    if detected:
        return detected, False
    return "bf16", True


def precision_suffix(precision):
    if precision == "int4":
        return "int4"
    if precision == "int8":
        return "int8"
    if precision == "fp8":
        return "fp8"
    return ""


def clean_version(version):
    return version.replace(".", "")


def derive_model_short(model_name, precision=None):
    name = normalize_name(model_name)
    suffix = precision_suffix(precision or "bf16")

    m = re.search(r"(?i)\bGLM-([0-9]+(?:\.[0-9]+)?)", name)
    if m:
        return "glm{}{}".format(clean_version(m.group(1)), suffix)

    m = re.search(r"(?i)\bQwen([0-9]+(?:\.[0-9]+)?)-([0-9]+)B", name)
    if m:
        return "qwen{}b{}{}".format(clean_version(m.group(1)), m.group(2), suffix)

    m = re.search(r"(?i)\bDeepSeek-R1-Distill-([A-Za-z0-9.]+)-([0-9]+)B", name)
    if m:
        base = re.sub(r"[^a-z0-9]", "", m.group(1).lower())
        return "dsr1distill{}b{}{}".format(base, m.group(2), suffix)

    m = re.search(r"(?i)\bMiniMax-M?([0-9]+(?:\.[0-9]+)?)", name)
    if m:
        marker = "m" if re.search(r"(?i)\bMiniMax-M", name) else ""
        return "minimax{}{}{}".format(marker, clean_version(m.group(1)), suffix)

    m = re.search(r"(?i)\bKimi-K?([0-9]+(?:\.[0-9]+)?)", name)
    if m:
        return "kimik{}{}".format(clean_version(m.group(1)), suffix)

    base = re.sub(r"[^a-z0-9]", "", name.lower())
    return "{}{}".format(base, suffix)


def default_port(model_name):
    name = normalize_name(model_name)
    if re.search(r"(?i)\bGLM-4\.7\b", name):
        return 9348
    if re.search(r"(?i)\bGLM-5\b", name) and not re.search(r"(?i)\bGLM-5\.1\b", name):
        return 9349
    if re.search(r"(?i)\bGLM-5\.1\b", name):
        return 9350
    return None


def collect_registered_ports():
    ports = set([9348, 9349, 9350])
    if PROFILES_DIR.exists():
        for profile in PROFILES_DIR.glob("*.yaml"):
            try:
                text = read_text(profile)
            except OSError:
                continue
            for match in re.finditer(r"(?m)^\s*default_port:\s*([0-9]+)\s*$", text):
                port = int(match.group(1))
                if 1 <= port <= 65535:
                    ports.add(port)
    if CONVENTIONS_FILE.exists():
        text = read_text(CONVENTIONS_FILE)
        for match in re.finditer(r"(?m)^\s*\|\s*[^|\n]+\s*\|\s*([0-9]+)\s*\|\s*$", text):
            port = int(match.group(1))
            if 1 <= port <= 65535:
                ports.add(port)
    return sorted(ports)


def resolve_port(args):
    used_ports = collect_registered_ports()
    if args.port is not None:
        args.port_source = "explicit"
        args.used_ports = used_ports
        return args

    glm_port = default_port(args.model_name)
    if glm_port is not None:
        args.port = glm_port
        args.port_source = "glm_default"
        args.used_ports = used_ports
        return args

    args.port = (max(used_ports) + 1) if used_ports else 9351
    args.port_source = "auto_next_available"
    args.used_ports = used_ports
    return args


def host_to_container_path(host_path):
    path = host_path.rstrip("/")
    mappings = [
        ("/public/opendas/DL_DATA/llm-models", "/model"),
        ("/public4/share", "/model1"),
        ("/public4/opendas/DL_DATA", "/model2"),
    ]
    for host_root, container_root in mappings:
        if path == host_root:
            return container_root
        if path.startswith(host_root + "/"):
            return container_root + path[len(host_root) :]
    return None


def relative_to_skill(path):
    p = Path(path)
    try:
        return str(p.resolve().relative_to(SKILL_ROOT)).replace("\\", "/")
    except ValueError:
        return None


def resolve_service_script(server_script, overwrite=False):
    src = Path(server_script)
    if not src.is_absolute():
        src = (SKILL_ROOT / server_script).resolve()
    if not src.exists():
        raise SystemExit("server_script does not exist: {}".format(src))

    rel = relative_to_skill(str(src))
    if rel and rel.startswith("scripts/server-scripts/"):
        return rel, src, False

    dest = SERVER_SCRIPTS_DIR / src.name
    if dest.exists() and not overwrite:
        raise SystemExit(
            "target service script already exists: {}; pass --overwrite to replace it".format(dest)
        )
    return "scripts/server-scripts/{}".format(src.name), src, True


def shell_quote(value):
    text = str(value)
    return "'" + text.replace("'", "'\\''") + "'"


def read_text(path):
    if not Path(path).exists():
        return ""
    return Path(path).read_text(encoding="utf-8")


def extract_vllm_params(script_text):
    params = {}
    pairs = [
        ("max_model_len", r"--max-model-len\s+([0-9]+)"),
        ("gpu_memory_utilization", r"--gpu-memory-utilization\s+([0-9.]+)"),
        ("quantization", r"(?:^|\s)-q\s+([A-Za-z0-9_]+)"),
        ("dtype", r"--dtype\s+([A-Za-z0-9_]+)"),
        ("max_num_seqs", r"--max-num-seqs\s+([0-9]+)"),
        ("max_num_batched_tokens", r"--max[-_]num[-_]batched[-_]tokens\s+([0-9]+)"),
        ("kv_cache_dtype", r"--kv-cache-dtype\s+([A-Za-z0-9_]+)"),
    ]
    for key, pattern in pairs:
        m = re.search(pattern, script_text, re.MULTILINE)
        if m:
            params[key] = m.group(1)
    return params


def extract_env_vars(script_text):
    result = []
    for match in re.finditer(r"^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)=", script_text, re.MULTILINE):
        name = match.group(1)
        if name not in result:
            result.append(name)
    return result


def existing_short_mapping(short_name):
    text = read_text(CONVENTIONS_FILE)
    for line in text.splitlines():
        parts = [p.strip() for p in line.strip().strip("|").split("|")]
        if len(parts) >= 2 and parts[1] == short_name:
            return parts[0]
    return None


def insert_row_after_table_heading(current_text, heading_pattern, row):
    lines = current_text.splitlines()
    if row in lines:
        return current_text
    heading_idx = None
    for idx, line in enumerate(lines):
        if re.search(heading_pattern, line):
            heading_idx = idx
            break
    if heading_idx is None:
        return current_text.rstrip() + "\n\n" + row + "\n"

    table_started = False
    insert_idx = None
    for idx in range(heading_idx + 1, len(lines)):
        line = lines[idx]
        if line.startswith("|"):
            table_started = True
            insert_idx = idx + 1
            continue
        if table_started:
            break
    if insert_idx is None:
        insert_idx = len(lines)
    lines.insert(insert_idx, row)
    return "\n".join(lines) + "\n"


def update_conventions(model_name, model_short, precision, port):
    text = read_text(CONVENTIONS_FILE)
    entry = "| {} | {} | {} |".format(model_name, model_short, precision)

    lines = text.splitlines()
    replaced = False
    for idx, line in enumerate(lines):
        if not line.startswith("|"):
            continue
        parts = [p.strip() for p in line.strip().strip("|").split("|")]
        if len(parts) >= 2 and parts[0] == model_name and parts[1] == model_short:
            lines[idx] = entry
            replaced = True
    text = "\n".join(lines) + ("\n" if lines else "")
    if not replaced:
        text = insert_row_after_table_heading(text, r"MODEL_SHORT", entry)

    port_label = "{} series".format(model_name.split("-W", 1)[0].split("-Channel", 1)[0])
    port_row = "| {} | {} |".format(port_label, port)
    if port and port_row not in text:
        text = insert_row_after_table_heading(text, r"port|端口|默认端口", port_row)

    CONVENTIONS_FILE.write_text(text, encoding="utf-8")


def yaml_quote(value):
    return '"{}"'.format(str(value).replace('"', '\\"'))


def write_profile(args, service_script, vllm_params, env_vars):
    profile = PROFILES_DIR / "{}.yaml".format(args.model_short)
    if profile.exists() and not args.overwrite:
        raise SystemExit("Profile already exists: {}; pass --overwrite to replace it".format(profile))
    lines = [
        "# Model Profile: {}".format(args.model_name),
        "# Generated at: {}".format(datetime.now().strftime("%Y-%m-%d %H:%M:%S")),
        "",
        "model:",
        "  display_name: {}".format(yaml_quote(args.model_name)),
        "  short_name: {}".format(yaml_quote(args.model_short)),
        "  host_model_path: {}".format(yaml_quote(args.host_model_path)),
        "  container_model_path: {}".format(yaml_quote(args.container_model_path)),
        "  served_model_id: null",
        "  bench_model_id: null",
        "  precision: {}".format(yaml_quote(args.precision)),
        "",
        "resource:",
        "  default_tp: {}".format(args.tp),
        "  min_gpu: {}".format(args.tp),
        "  default_port: {}".format(args.port),
        "",
        "service:",
        "  script: {}".format(yaml_quote(service_script)),
        "  vllm_params:",
    ]
    if vllm_params:
        for key in sorted(vllm_params):
            value = vllm_params[key]
            if re.match(r"^[0-9.]+$", value):
                lines.append("    {}: {}".format(key, value))
            else:
                lines.append("    {}: {}".format(key, yaml_quote(value)))
    else:
        lines.append("    {}")
    lines.append("  env_vars:")
    if env_vars:
        lines.extend(["    - {}".format(name) for name in env_vars])
    else:
        lines.append("    []")
    lines.extend(
        [
            "",
            "health_check:",
            '  endpoint: "/v1/chat/completions"',
            '  prompt: "你好"',
            "  timeout_seconds: {}".format(args.timeout),
            "",
        ]
    )
    profile.write_text("\n".join(lines), encoding="utf-8")
    return profile


def write_example(args, service_script):
    example = EXAMPLES_DIR / "{}-test-task.yaml".format(args.model_short)
    if example.exists() and not args.overwrite:
        raise SystemExit("Example already exists: {}; pass --overwrite to replace it".format(example))
    content = """task:
  name: vllm_perf_{short}
  run_id: auto
  owner: {owner}
  description: "{model_name} custom smoke"

mode: single

paths:
  skill_host_root: {skill_host_root}
  skill_container_root: {skill_container_root}
  output_host_root: {output_host_root}
  output_container_root: {output_container_root}

image:
  name: null
  pull_policy: if_not_present

node:
  ip: null
  dcu_type: null
  gpu_count: 8

container:
  name_template: "{container_prefix}-<MMDD>-<MODEL_SHORT>-<IMAGE_PREFIX>"

models:
  - name: "{model_name}"
    model_short: "{short}"
    host_model_path: {host_model_path}
    container_model_path: {container_model_path}
    served_model_id: null
    bench_model_id: null
    tp: {tp}
    port: {port}
    gpu_range: "{gpu_range}"
    service_script: {service_script}

service:
  health_check:
    endpoint: /v1/chat/completions
    timeout_seconds: {timeout}

test:
  mode: custom
  params:
    input_lens: "512"
    output_len: 32
    concurrencies: "1"
    num_prompts_mult: 1
    percentiles: "50,95,99"

output:
  work_dir: {output_host_root}/work_dirs
  report_dir: {output_host_root}/reports
  csv_dir: {output_host_root}/csvs
""".format(
        short=args.model_short,
        model_name=args.model_name,
        skill_host_root=args.skill_host_root,
        skill_container_root=DEFAULT_SKILL_CONTAINER_ROOT,
        output_host_root=args.output_host_root,
        output_container_root=args.output_container_root,
        container_prefix=args.container_prefix,
        owner=args.user,
        host_model_path=args.host_model_path,
        container_model_path=args.container_model_path,
        service_script=service_script,
        tp=args.tp,
        port=args.port,
        gpu_range=args.gpu_range,
        timeout=args.timeout,
    )
    example.write_text(content, encoding="utf-8")
    return example


def print_command(name, command):
    print("{}=".format(name))
    print(" \\\n  ".join(shell_quote(x) if any(c in str(x) for c in " <>") else str(x) for x in command))


def print_run_single_task(args, service_script):
    command = [
        "bash",
        args.run_single_task,
        "--user",
        args.user,
        "--abbr",
        args.abbr,
        "--node",
        "<NODE>",
        "--image",
        "<IMAGE>",
        "--model-name",
        args.model_name,
        "--model-short",
        args.model_short,
        "--host-model-path",
        args.host_model_path,
        "--container-model-path",
        args.container_model_path,
        "--server-script",
        service_script,
        "--output-host-root",
        args.output_host_root,
        "--output-container-root",
        args.output_container_root,
        "--container-prefix",
        args.container_prefix,
        "--port",
        args.port,
        "--tp",
        args.tp,
        "--gpu-range",
        args.gpu_range,
        "--test-mode",
        "custom",
        "--input-lens",
        "512",
        "--output-len",
        "32",
        "--concurrencies",
        "1",
        "--num-prompts-mult",
        "1",
        "--percentiles",
        "50,95,99",
        "--timeout",
        args.timeout,
        "--image-prefix",
        "<IMAGE_PREFIX>",
        "--dry-run",
    ]
    print_command("RUN_SINGLE_TASK_DRY_RUN_CMD", command)


def print_standardize_command(args, service_script):
    command = [
        "bash",
        args.standardize_server_script,
        "--user",
        args.user,
        "--abbr",
        args.abbr,
        "--model-name",
        args.model_name,
        "--server-script",
        service_script,
        "--output-host-root",
        args.output_host_root,
        "--output-container-root",
        args.output_container_root,
        "--container-prefix",
        args.container_prefix,
        "--container-model-path",
        args.container_model_path,
        "--port",
        args.port,
        "--tp",
        args.tp,
        "--gpu-range",
        args.gpu_range,
        "--dry-run",
    ]
    if args.model_short:
        command.extend(["--model-short", args.model_short])
    print_command("NEXT_STEP_STANDARDIZE_CMD", command)


def is_glm_model(model_name):
    return re.search(r"(?i)\bGLM-", model_name) is not None


def infer_tp_from_script(script_text):
    patterns = [
        r"(?:^|\s)-tp\s+([0-9]+)(?:\s|\\|$)",
        r"--tensor-parallel-size\s+([0-9]+)(?:\s|\\|$)",
        r"^\s*export\s+TP_SIZE=([0-9]+)\s*$",
        r"^\s*export\s+TP=([0-9]+)\s*$",
        r"^\s*TP_SIZE=([0-9]+)\s*$",
        r"^\s*TP=([0-9]+)\s*$",
        r"^\s*export\s+TP_SIZE=\$\{TP:-([0-9]+)\}\s*$",
        r"^\s*export\s+TP=\$\{TP:-([0-9]+)\}\s*$",
    ]
    for pattern in patterns:
        m = re.search(pattern, script_text, re.MULTILINE)
        if m:
            return int(m.group(1))
    return None


def default_gpu_range_for_tp(tp):
    return ",".join(str(i) for i in range(int(tp)))


def validate_server_script(script_text):
    warnings = []
    if not re.search(r"vllm\s+serve[\s\S]*\$\{?MODEL_PATH", script_text):
        warnings.append("server script does not pass MODEL_PATH to vllm serve")
    if "GPU_RANGE" not in script_text:
        warnings.append("server script does not expose GPU_RANGE")
    if not re.search(r"--port\s+['\"]?\$\{?PORT", script_text):
        warnings.append("server script does not pass PORT to vllm serve")
    if not re.search(r"(?:-tp|--tensor-parallel-size)\s+['\"]?\$\{?(?:TP|TP_SIZE)", script_text):
        warnings.append("server script does not pass TP/TP_SIZE to vllm serve")
    return warnings


def parse_args():
    parser = argparse.ArgumentParser(description="Register a model for vLLM perf validation")
    parser.add_argument("--user")
    parser.add_argument("--abbr")
    parser.add_argument("--home-root", default=DEFAULT_HOME_ROOT)
    parser.add_argument("--host-home-root")
    parser.add_argument("--skill-host-root")
    parser.add_argument("--output-host-root")
    parser.add_argument("--output-container-root", default=DEFAULT_OUTPUT_CONTAINER_ROOT)
    parser.add_argument("--container-prefix")
    parser.add_argument("--model-name", required=True)
    parser.add_argument("--host-model-path", required=True)
    parser.add_argument("--server-script", required=True)
    parser.add_argument("--model-short")
    parser.add_argument("--container-model-path")
    parser.add_argument("--port", type=int)
    parser.add_argument("--tp", type=int)
    parser.add_argument("--gpu-range")
    parser.add_argument("--precision")
    parser.add_argument("--timeout", type=int)
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--allow-static-server-script", action="store_true")
    return parser.parse_args()


def apply_runtime_config(args):
    args.user = args.user or DEFAULT_USER
    if not args.user or args.user == "<user>":
        raise SystemExit("missing runtime user; pass --user <linux_user>")
    args.abbr = args.abbr or args.user
    args.home_root = args.home_root.rstrip("/")
    if args.home_root == "/public2/home":
        args.home_root = "/public/home"
    args.host_home_root = (args.host_home_root or args.home_root + "/" + args.user).rstrip("/")
    args.skill_host_root = (
        args.skill_host_root
        or args.host_home_root + "/.claude/skills/vllm-perf-validation-single"
    ).rstrip("/")
    args.output_host_root = (
        args.output_host_root
        or args.host_home_root + "/skilltest/vllm-perf-validation-single"
    ).rstrip("/")
    args.output_container_root = args.output_container_root.rstrip("/")
    args.container_prefix = args.container_prefix or args.abbr + "-agent-test"
    args.run_single_task = args.skill_host_root + "/scripts/ops/run_single_task.sh"
    args.standardize_server_script = args.skill_host_root + "/scripts/ops/standardize_server_script.sh"
    return args


def enrich_args(args, script_text, service_script):
    args = apply_runtime_config(args)
    args.model_name = normalize_name(args.model_name)
    args.host_model_path = args.host_model_path.rstrip("/")
    args.precision, args.precision_defaulted = infer_precision(
        args.model_name, service_script, args.precision
    )
    args.model_short = args.model_short or derive_model_short(args.model_name, args.precision)
    if not re.match(r"^[a-z0-9]+$", args.model_short):
        raise SystemExit("MODEL_SHORT may only contain lowercase letters and digits: {}".format(args.model_short))
    if not args.container_model_path:
        args.container_model_path = host_to_container_path(args.host_model_path)
    if not args.container_model_path:
        raise SystemExit("cannot infer container path from host_model_path; pass --container-model-path")
    args = resolve_port(args)
    if args.tp is None:
        if is_glm_model(args.model_name):
            args.tp = 8
        else:
            args.tp = infer_tp_from_script(script_text)
            if args.tp is None:
                raise SystemExit("non-GLM model requires --tp or a server script with static TP")
    if args.gpu_range is None:
        if is_glm_model(args.model_name):
            args.gpu_range = "0,1,2,3,4,5,6,7"
        else:
            args.gpu_range = default_gpu_range_for_tp(args.tp)
    if args.timeout is None:
        if args.model_short.startswith("glm5") and not args.model_short.startswith("glm51"):
            args.timeout = 3600
        else:
            args.timeout = 2400
    return args


def main():
    args = parse_args()
    service_script, src, should_copy = resolve_service_script(
        args.server_script, overwrite=args.overwrite
    )
    script_text = read_text(src)
    args = enrich_args(args, script_text, service_script)

    existing = existing_short_mapping(args.model_short)
    if existing and existing != args.model_name:
        raise SystemExit(
            "MODEL_SHORT conflict: {} already maps to {}; pass another --model-short".format(
                args.model_short, existing
            )
        )

    vllm_params = extract_vllm_params(script_text)
    env_vars = extract_env_vars(script_text)
    warnings = validate_server_script(script_text)
    if warnings and not args.dry_run and not args.allow_static_server_script:
        for warning in warnings:
            print("WARN={}".format(warning))
        print_standardize_command(args, service_script)
        raise SystemExit(
            "server script is not standardized; run standardize_server_script.sh first or pass --allow-static-server-script"
        )

    print("MODEL_NAME={}".format(args.model_name))
    print("MODEL_SHORT={}".format(args.model_short))
    print("MODEL_PRECISION={}".format(args.precision))
    print("PRECISION={}".format(args.precision))
    print("HOST_MODEL_PATH={}".format(args.host_model_path))
    print("CONTAINER_MODEL_PATH={}".format(args.container_model_path))
    print("PORT={}".format(args.port))
    print("PORT_SOURCE={}".format(args.port_source))
    print("USED_PORTS={}".format(",".join(str(port) for port in args.used_ports)))
    print("TP={}".format(args.tp))
    print("GPU_RANGE={}".format(args.gpu_range))
    print("SERVICE_SCRIPT={}".format(service_script))
    print("USER={}".format(args.user))
    print("ABBR={}".format(args.abbr))
    print("SKILL_HOST_ROOT={}".format(args.skill_host_root))
    print("OUTPUT_HOST_ROOT={}".format(args.output_host_root))
    print("CONTAINER_PREFIX={}".format(args.container_prefix))
    print("COMPUTE_DTYPE={}".format(vllm_params.get("dtype", "")))
    print("KV_CACHE_DTYPE={}".format(vllm_params.get("kv_cache_dtype", "")))
    if getattr(args, "precision_defaulted", False):
        print("WARN=precision defaulted to bf16; pass --precision to confirm")
    for warning in warnings:
        print("WARN={}".format(warning))
    if warnings:
        print_standardize_command(args, service_script)

    if args.dry_run:
        print("DRY_RUN=1, no files written.")
        print_run_single_task(args, service_script)
        return 0

    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    EXAMPLES_DIR.mkdir(parents=True, exist_ok=True)
    SERVER_SCRIPTS_DIR.mkdir(parents=True, exist_ok=True)
    if should_copy:
        dest = SERVER_SCRIPTS_DIR / Path(service_script).name
        shutil.copyfile(str(src), str(dest))
        try:
            os.chmod(str(dest), 0o755)
        except OSError:
            pass
        print("COPIED_SERVER_SCRIPT={}".format(dest))

    profile = write_profile(args, service_script, vllm_params, env_vars)
    example = write_example(args, service_script)
    update_conventions(args.model_name, args.model_short, args.precision, args.port)
    print("PROFILE={}".format(profile))
    print("EXAMPLE={}".format(example))
    print("CONVENTIONS={}".format(CONVENTIONS_FILE))
    print_run_single_task(args, service_script)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

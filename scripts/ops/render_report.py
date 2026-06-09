#!/usr/bin/env python3
"""根据 state.json 和 CSV 结果生成 vLLM 性能报告。兼容 Python 3.6+。"""

import argparse
import csv
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from statistics import mean


SKILL_ROOT = Path(__file__).resolve().parents[2]


def infer_user_from_skill_root():
    root = SKILL_ROOT.as_posix().rstrip("/")
    for marker in ("/public/home/", "/public2/home/"):
        if marker in root:
            tail = root.split(marker, 1)[1]
            user = tail.split("/", 1)[0]
            if user:
                return user
    return os.environ.get("USER") or os.environ.get("LOGNAME") or "<user>"


DEFAULT_OUTPUT_HOST_ROOT = "/public/home/{}/skilltest/vllm-perf-validation-single".format(
    infer_user_from_skill_root()
)


OUTPUT_CONTAINER_ROOT = os.environ.get(
    "OUTPUT_CONTAINER_ROOT", "/mnt/skilltest/vllm-perf-validation-single"
)
OUTPUT_HOST_ROOT = os.environ.get(
    "OUTPUT_HOST_ROOT", DEFAULT_OUTPUT_HOST_ROOT
)


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def as_float(value):
    if value in (None, ""):
        return None
    try:
        return float(value)
    except ValueError:
        return None


def deep_get(data, path, default=None):
    current = data
    for key in path.split("."):
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


def set_path(data, path, value):
    current = data
    parts = path.split(".")
    for key in parts[:-1]:
        child = current.get(key)
        if not isinstance(child, dict):
            child = {}
            current[key] = child
        current = child
    current[parts[-1]] = value


def host_equivalent(path):
    raw = str(path)
    if raw.startswith(OUTPUT_CONTAINER_ROOT):
        return Path(OUTPUT_HOST_ROOT + raw[len(OUTPUT_CONTAINER_ROOT) :])
    return path


def readable_path(path):
    if path.exists():
        return path
    mapped = host_equivalent(path)
    if mapped.exists():
        return mapped
    return path


def writable_path(path):
    raw = str(path)
    if raw.startswith(OUTPUT_CONTAINER_ROOT):
        if Path(OUTPUT_CONTAINER_ROOT).exists():
            return path
        return host_equivalent(path)
    return path


def load_csv(csv_file):
    with csv_file.open("r", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def normalize_status(row):
    status = (row.get("status") or "").strip().upper()
    if status:
        return status
    sla_pass = (row.get("sla_pass") or "").strip().lower()
    if sla_pass in {"true", "1", "yes", "y", "pass"}:
        return "PASS"
    if sla_pass in {"false", "0", "no", "n", "fail"}:
        return "FAIL"
    return "SKIPPED"


def truthy(value):
    return str(value or "").strip().lower() in {"true", "1", "yes", "y", "pass"}


def summarize(rows):
    statuses = [normalize_status(row) for row in rows]
    numeric = {
        "max_qps": ["rps", "request_throughput", "qps"],
        "max_output_tok_s": ["generate_throughput_tok_s", "output_token_throughput"],
        "max_total_tok_s": ["total_throughput_tok_s", "total_token_throughput"],
        "avg_ttft_ms": ["mean_ttft", "mean_ttft_ms"],
        "avg_tpot_ms": ["mean_tpot", "mean_tpot_ms"],
        "avg_itl_ms": ["mean_itl", "mean_itl_ms"],
    }
    result = {
        "total_scenarios": len(rows),
        "passed": statuses.count("PASS"),
        "partial": statuses.count("PARTIAL"),
        "failed": statuses.count("FAIL"),
        "skipped": statuses.count("SKIPPED"),
        "max_effective_cache_hit_pct": None,
        "completed_requests": None,
        "failed_requests": None,
        "best_sla_concurrency": None,
    }
    for out_key, candidates in numeric.items():
        values = []
        for row in rows:
            for key in candidates:
                value = as_float(row.get(key))
                if value is not None:
                    values.append(value)
                    break
        if not values:
            result[out_key] = None
        elif out_key.startswith("avg_"):
            result[out_key] = round(mean(values), 4)
        else:
            result[out_key] = round(max(values), 4)

    effective_values = [as_float(row.get("effective_cache_hit_pct")) for row in rows]
    effective_values = [value for value in effective_values if value is not None]
    if effective_values:
        result["max_effective_cache_hit_pct"] = round(max(effective_values), 4)

    completed = [as_float(row.get("completed_requests")) for row in rows]
    failed = [as_float(row.get("failed_requests")) for row in rows]
    completed = [value for value in completed if value is not None]
    failed = [value for value in failed if value is not None]
    if completed:
        result["completed_requests"] = int(sum(completed))
    if failed:
        result["failed_requests"] = int(sum(failed))

    best_concurrency = []
    for row, status in zip(rows, statuses):
        if status == "PASS" or truthy(row.get("sla_pass")):
            value = as_float(row.get("concurrency"))
            if value is not None:
                best_concurrency.append(value)
    if best_concurrency:
        result["best_sla_concurrency"] = int(max(best_concurrency))

    if result["failed"]:
        result["status"] = "FAIL"
    elif result["partial"]:
        result["status"] = "PARTIAL"
    elif result["passed"] == len(rows) and rows:
        result["status"] = "PASS"
    else:
        result["status"] = "SKIPPED"
    return result


def first_state_path(state, keys):
    for key in keys:
        value = deep_get(state, key)
        if value:
            return str(value)
    return None


def main():
    parser = argparse.ArgumentParser(description="根据 state.json 和 CSV 生成 vLLM 性能报告")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--csv", type=Path)
    parser.add_argument("--report-dir", required=True, type=Path)
    args = parser.parse_args()

    state_file = readable_path(args.state)
    if not state_file.exists():
        raise SystemExit(
            "state 文件不存在: {}；也未找到宿主机映射路径: {}".format(
                args.state, host_equivalent(args.state)
            )
        )
    state = json.loads(state_file.read_text(encoding="utf-8-sig"))

    csv_file = args.csv
    if csv_file is None:
        csv_path = first_state_path(
            state,
            ["paths.csv_file_host", "paths.csv_file", "paths.csv_file_container"],
        )
        if not csv_path:
            raise SystemExit("未传入 --csv，且 state 中没有 paths.csv_file_host / paths.csv_file")
        csv_file = Path(csv_path)
    csv_file = readable_path(csv_file)
    if not csv_file.exists():
        raise SystemExit("CSV 文件不存在: {}".format(csv_file))

    rows = load_csv(csv_file)
    summary = summarize(rows)
    final_status = summary["status"]
    if state.get("status") in {"SERVICE_FAILED", "SERVICE_TIMEOUT", "BENCH_FAILED", "STOP_FAILED"}:
        final_status = "FAIL"

    report_dir = writable_path(args.report_dir)
    log_file = deep_get(state, "paths.log_file_host") or deep_get(state, "paths.log_file")
    pid_file = deep_get(state, "paths.pid_file_host") or deep_get(state, "paths.pid_file")
    work_dir_container = deep_get(state, "paths.work_dir_container") or deep_get(state, "paths.work_dir")
    report = {
        "run_id": args.run_id,
        "generated_at": utc_now_iso(),
        "status": final_status,
        "node": state.get("node"),
        "image": state.get("image"),
        "container": state.get("container", {}),
        "model": state.get("model", {}),
        "deployment": {
            "status": "PASS" if state.get("status") not in {"SERVICE_FAILED", "SERVICE_TIMEOUT"} else "FAIL",
            "startup_duration_seconds": deep_get(state, "timing.startup_duration_seconds"),
            "readiness_duration_seconds": deep_get(state, "timing.readiness_duration_seconds"),
            "stop_epoch": deep_get(state, "timing.stop_epoch"),
            "port_released": deep_get(state, "service.port_released"),
            "gpu_topology": deep_get(state, "node_info.gpu_topology"),
            "log_file": log_file,
            "pid_file": pid_file,
        },
        "test": {
            "mode": deep_get(state, "test.mode"),
            "status": deep_get(state, "test.status", summary["status"]),
            "csv_file": str(csv_file),
            "pchit_json_file": deep_get(state, "paths.pchit_json_file_host")
            or deep_get(state, "paths.pchit_json_file"),
        },
        "results": {
            "csv_file": str(csv_file),
            "pchit_json_file": deep_get(state, "paths.pchit_json_file_host")
            or deep_get(state, "paths.pchit_json_file"),
            "log_file": log_file,
            "summary": summary,
        },
        "pchit": state.get("pchit", {}),
        "paths": {
            "state_file": str(state_file),
            "report_json": str(report_dir / "{}.json".format(args.run_id)),
            "report_md": str(report_dir / "{}.md".format(args.run_id)),
            "work_dir_host": deep_get(state, "paths.work_dir_host"),
            "work_dir_container": work_dir_container,
        },
        "failure": state.get("failure", {}),
        "baseline": state.get("baseline", {"status": "baseline_missing"}),
        "ops": state.get("ops", {}),
        "state": state,
    }

    report_dir.mkdir(parents=True, exist_ok=True)
    json_path = report_dir / "{}.json".format(args.run_id)
    md_path = report_dir / "{}.md".format(args.run_id)
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    md_lines = [
        "# vLLM 性能报告: {}".format(args.run_id),
        "",
        "- 状态: {}".format(final_status),
        "- 节点: {}".format(report["node"]),
        "- 镜像: {}".format(report["image"]),
        "- 容器: {}".format(deep_get(state, "container.name")),
        "- 模型: {}".format(deep_get(state, "model.name")),
        "- host_model_path: `{}`".format(deep_get(state, "model.host_model_path")),
        "- container_model_path: `{}`".format(deep_get(state, "model.container_model_path")),
        "- served_model_id: `{}`".format(deep_get(state, "model.served_model_id")),
        "- bench_model_id: `{}`".format(deep_get(state, "model.bench_model_id")),
        "- 启动耗时秒: {}".format(deep_get(state, "timing.startup_duration_seconds")),
        "- 就绪耗时秒: {}".format(deep_get(state, "timing.readiness_duration_seconds")),
        "- 停止时间戳: {}".format(deep_get(state, "timing.stop_epoch")),
        "- 端口已释放: {}".format(deep_get(state, "service.port_released")),
        "- 工作目录(宿主机): `{}`".format(deep_get(state, "paths.work_dir_host")),
        "- 工作目录(容器): `{}`".format(work_dir_container),
        "- CSV: `{}`".format(csv_file),
        "- 日志: `{}`".format(log_file),
        "- 场景数: {}".format(summary["total_scenarios"]),
        "- 通过: {}".format(summary["passed"]),
        "- 部分通过: {}".format(summary["partial"]),
        "- 失败: {}".format(summary["failed"]),
        "- 最大 QPS: {}".format(summary["max_qps"]),
        "- 最大输出 tok/s: {}".format(summary["max_output_tok_s"]),
        "- 最大总 tok/s: {}".format(summary["max_total_tok_s"]),
        "- 平均 TTFT ms: {}".format(summary["avg_ttft_ms"]),
        "- 平均 TPOT ms: {}".format(summary["avg_tpot_ms"]),
        "- 平均 ITL ms: {}".format(summary["avg_itl_ms"]),
        "- Baseline: {}".format(report["baseline"].get("status")),
        "- Ops version: {}".format(deep_get(state, "ops.version")),
        "",
    ]
    if deep_get(state, "test.mode") == "pchit" or state.get("pchit"):
        benchmark = state.get("pchit", {}).get("benchmark", {})
        warmup = state.get("pchit", {}).get("warmup", {})
        md_lines.extend(
            [
                "## Prefix Cache Benchmark",
                "",
                "- Mode: {}".format(benchmark.get("mode")),
                "- Target cache hit pct: {}".format(
                    benchmark.get("target_pct") or warmup.get("target_pct")
                ),
                "- Max effective cache hit pct: {}".format(
                    summary.get("max_effective_cache_hit_pct")
                ),
                "- Best SLA concurrency: {}".format(summary.get("best_sla_concurrency")),
                "- Completed requests: {}".format(summary.get("completed_requests")),
                "- Failed requests: {}".format(summary.get("failed_requests")),
                "- pchit JSON: `{}`".format(
                    deep_get(state, "paths.pchit_json_file_host")
                    or deep_get(state, "paths.pchit_json_file")
                    or ""
                ),
                "",
            ]
        )
    if report["failure"]:
        md_lines.extend(
            [
                "## 失败信息",
                "",
                "```json\n{}\n```".format(json.dumps(report["failure"], ensure_ascii=False, indent=2)),
                "",
            ]
        )
    md_path.write_text("\n".join(md_lines), encoding="utf-8")
    set_path(state, "paths.report_json_host", str(json_path))
    set_path(state, "paths.report_md_host", str(md_path))
    set_path(state, "report.run_id", args.run_id)
    set_path(state, "report.status", final_status)
    set_path(state, "report.generated_at", report["generated_at"])
    if deep_get(state, "test.mode") == "pchit" or state.get("pchit"):
        set_path(
            state,
            "pchit.benchmark.effective_cache_hit_pct",
            summary.get("max_effective_cache_hit_pct"),
        )
        set_path(
            state,
            "pchit.benchmark.best_sla_concurrency",
            summary.get("best_sla_concurrency"),
        )
        set_path(
            state,
            "pchit.benchmark.completed_requests",
            summary.get("completed_requests"),
        )
        set_path(
            state,
            "pchit.benchmark.failed_requests",
            summary.get("failed_requests"),
        )
    try:
        state_file.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except OSError as exc:
        print("WARN_STATE_UPDATE_FAILED={}".format(exc))
    print("REPORT_JSON_HOST={}".format(json_path))
    print("REPORT_MD_HOST={}".format(md_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

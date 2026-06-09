#!/usr/bin/env python3
"""Configure user-specific paths and container prefix for this skill.

This script is local-only. It does not connect to SSH, Docker, or GPUs.
It rewrites text files under the skill so a new user can switch the default
host paths and container-name prefix in one controlled step.
"""

import argparse
import os
import shutil
from datetime import datetime
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parents[2]
SKILL_NAME = "vllm-perf-validation-single"

DEFAULT_HOME_ROOTS = ["/public/home", "/public2/home"]
DEFAULT_SKILL_CONTAINER_ROOT = "/mnt/.claude/skills/{}".format(SKILL_NAME)
DEFAULT_OUTPUT_CONTAINER_ROOT = "/mnt/skilltest/{}".format(SKILL_NAME)

SCAN_ROOTS = [
    "README.md",
    "SKILL.md",
    "task.yaml",
    "agents",
    "references",
    "scripts",
]

SKIP_DIRS = set(
    [
        ".git",
        ".idea",
        ".vscode",
        "__pycache__",
        "tmp",
        "logs",
        "reports",
        "csvs",
        "work_dirs",
    ]
)
SKIP_SUFFIXES = set([".pyc", ".pyo", ".png", ".jpg", ".jpeg", ".gif", ".zip", ".tar", ".gz"])


def parse_args():
    parser = argparse.ArgumentParser(
        description="Configure skill host paths and Docker container prefix for a new user."
    )
    parser.add_argument("--user", required=True, help="Target Linux username, for example zhangsan")
    parser.add_argument("--abbr", required=True, help="Short personal prefix, for example zs")
    parser.add_argument("--from-user", help="Optional legacy username to replace in text files")
    parser.add_argument("--from-container-prefix", help="Optional legacy container prefix to replace")
    parser.add_argument("--from-owner", help="Optional legacy owner value to replace")
    parser.add_argument("--home-root", default="/public/home")
    parser.add_argument("--skill-host-root")
    parser.add_argument("--output-host-root")
    parser.add_argument("--container-prefix")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--backup", action="store_true")
    return parser.parse_args()


def normalize_abs_path(path):
    return str(path).rstrip("/")


def build_config(args):
    home_root = normalize_abs_path(args.home_root)
    host_home_root = "{}/{}".format(home_root, args.user)
    skill_host_root = args.skill_host_root or "{}/.claude/skills/{}".format(
        host_home_root, SKILL_NAME
    )
    output_host_root = args.output_host_root or "{}/skilltest/{}".format(host_home_root, SKILL_NAME)
    container_prefix = args.container_prefix or "{}-agent-test".format(args.abbr)
    return {
        "user": args.user,
        "abbr": args.abbr,
        "home_root": home_root,
        "host_home_root": normalize_abs_path(host_home_root),
        "skill_host_root": normalize_abs_path(skill_host_root),
        "output_host_root": normalize_abs_path(output_host_root),
        "skill_container_root": DEFAULT_SKILL_CONTAINER_ROOT,
        "output_container_root": DEFAULT_OUTPUT_CONTAINER_ROOT,
        "container_prefix": container_prefix,
        "from_user": args.from_user,
        "from_container_prefix": args.from_container_prefix,
        "from_owner": args.from_owner,
    }


def candidate_files():
    for item in SCAN_ROOTS:
        root = SKILL_ROOT / item
        if not root.exists():
            continue
        if root.is_file():
            yield root
            continue
        for current, dirs, files in os.walk(str(root)):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for name in files:
                path = Path(current) / name
                if path.suffix.lower() in SKIP_SUFFIXES:
                    continue
                yield path


def read_text(path):
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return None


def build_replacements(config):
    replacements = []
    if config.get("from_user"):
        for root in DEFAULT_HOME_ROOTS:
            old_home = "{}/{}".format(root, config["from_user"])
            old_skill = "{}/.claude/skills/{}".format(old_home, SKILL_NAME)
            old_output = "{}/skilltest/{}".format(old_home, SKILL_NAME)
            replacements.extend(
                [
                    (old_skill, config["skill_host_root"]),
                    (old_output, config["output_host_root"]),
                    (old_home, config["host_home_root"]),
                ]
            )
        replacements.append((config["from_user"], config["user"]))
    if config.get("from_container_prefix"):
        replacements.append((config["from_container_prefix"], config["container_prefix"]))
    if config.get("from_owner"):
        replacements.append(
            ("owner: {}".format(config["from_owner"]), "owner: {}".format(config["user"]))
        )
    return replacements


def replace_text(text, replacements):
    changed = text
    counts = []
    for old, new in replacements:
        count = changed.count(old)
        if count:
            changed = changed.replace(old, new)
            counts.append((old, new, count))
    return changed, counts


def backup_file(path, timestamp):
    backup = path.with_name("{}{}.bak.{}".format(path.name, "", timestamp))
    shutil.copyfile(str(path), str(backup))
    return backup


def print_config(config):
    print("USER={}".format(config["user"]))
    print("ABBR={}".format(config["abbr"]))
    print("HOST_HOME_ROOT={}".format(config["host_home_root"]))
    print("SKILL_HOST_ROOT={}".format(config["skill_host_root"]))
    print("SKILL_CONTAINER_ROOT={}".format(config["skill_container_root"]))
    print("OUTPUT_HOST_ROOT={}".format(config["output_host_root"]))
    print("OUTPUT_CONTAINER_ROOT={}".format(config["output_container_root"]))
    print("CONTAINER_PREFIX={}".format(config["container_prefix"]))


def print_settings_fragment(config):
    skill_root = config["skill_host_root"]
    output_root = config["output_host_root"]
    print("SETTINGS_ALLOW_FRAGMENT_BEGIN")
    print('      "Read({}/**)",'.format(skill_root))
    print('      "Read({}/**)",'.format(output_root))
    for script in [
        "configure_skill_user.sh",
        "standardize_server_script.sh",
        "register_model.sh",
        "run_single_task.sh",
        "resume_single_task.sh",
        "show_state.sh",
    ]:
        print('      "Bash(bash {}/scripts/ops/{} *)",'.format(skill_root, script))
    print("SETTINGS_ALLOW_FRAGMENT_END")


def main():
    args = parse_args()
    if args.apply and args.dry_run:
        raise SystemExit("choose only one of --dry-run or --apply")
    dry_run = args.dry_run or not args.apply
    config = build_config(args)
    replacements = build_replacements(config)
    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")

    print("MODE={}".format("DRY_RUN" if dry_run else "APPLY"))
    if dry_run:
        print("DRY_RUN=1, no files written.")
    else:
        print("APPLY=1, files may be updated.")
    print_config(config)

    changed_files = []
    for path in candidate_files():
        text = read_text(path)
        if text is None:
            continue
        new_text, counts = replace_text(text, replacements)
        if new_text == text:
            continue
        rel = str(path.relative_to(SKILL_ROOT)).replace("\\", "/")
        changed_files.append((path, rel, counts))
        print("CHANGE_FILE={}".format(rel))
        for old, new, count in counts:
            print("  {} -> {} ({})".format(old, new, count))
        if not dry_run:
            if args.backup:
                backup = backup_file(path, timestamp)
                print("  BACKUP={}".format(str(backup)))
            path.write_text(new_text, encoding="utf-8")

    print("CHANGED_FILE_COUNT={}".format(len(changed_files)))
    print_settings_fragment(config)
    if dry_run:
        print("NEXT_STEP_APPLY_CMD=")
        print(
            "bash {}/scripts/ops/configure_skill_user.sh --user {} --abbr {} --apply --backup".format(
                config["skill_host_root"], config["user"], config["abbr"]
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

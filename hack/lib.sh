#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="${LOG_PREFIX:-verify}"
LOG_TIMESTAMP="${LOG_TIMESTAMP:-false}"

log() {
  if [[ "${LOG_TIMESTAMP}" == "true" ]]; then
    printf '\033[1;34m[%s %s]\033[0m %s\n' "${LOG_PREFIX}" "$(date -u +%H:%M:%SZ)" "$*"
  else
    printf '\033[1;34m[%s]\033[0m %s\n' "${LOG_PREFIX}" "$*"
  fi
}

pass() {
  printf '\033[1;32m[PASS]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2
  exit 1
}

check_no_banned_terms() {
  python3 - "$@" <<'PY'
import pathlib
import re
import sys

banned = [
    (re.compile("ate" + "-" + "cluster", re.IGNORECASE), "personal cluster name"),
    (re.compile("mofi" + "labs", re.IGNORECASE), "personal project ID"),
    (re.compile(r"fluid\s+compute", re.IGNORECASE), "internal term 'fluid compute'"),
]

for arg in sys.argv[1:]:
    p = pathlib.Path(arg)
    files = [p] if p.is_file() else [f for f in p.rglob("*") if f.is_file()]
    for f in files:
        if ".git" in f.parts or f.name == "lib.sh":
            continue
        text = f.read_text(encoding="utf-8", errors="ignore")
        for pat, desc in banned:
            if pat.search(text):
                raise SystemExit(f"Found banned term ({desc}) in {f}")
PY
}

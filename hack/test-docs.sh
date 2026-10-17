#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_PREFIX="test-docs"
# shellcheck source=hack/lib.sh
source "${SCRIPT_DIR}/lib.sh"

log "Step 1: Checking required documentation and ADR files exist..."
REQUIRED_FILES=(
  "README.md"
  "BLOG-01-STARTUP-BOOST.md"
  "BLOG-02-VPA-HPA-RIGHTSIZING.md"
  "TROUBLESHOOTING.md"
  "GLOSSARY.md"
  "AGENTS.md"
  "docs/adr/0001-readiness-probe-and-zero-duration-for-hpa-safe-startup-boost.md"
  "docs/adr/0002-requests-and-limits-qos-preservation-for-in-place-unboost.md"
  "docs/adr/0003-cooperative-vpa-hpa-rightsizing-policy-and-teardown-safety.md"
  "docs/adr/0004-admission-only-boost-semantics-on-container-restart.md"
)
for rel in "${REQUIRED_FILES[@]}"; do
  [[ -f "${REPO_ROOT}/${rel}" ]] || fail "Missing required doc file: ${rel}"
done
pass "All required documentation and ADR files exist."

log "Step 2: Checking banned terms (personal cluster/project names and internal terminology)..."
check_no_banned_terms \
  "${REPO_ROOT}/README.md" \
  "${REPO_ROOT}/BLOG-01-STARTUP-BOOST.md" \
  "${REPO_ROOT}/BLOG-02-VPA-HPA-RIGHTSIZING.md" \
  "${REPO_ROOT}/TROUBLESHOOTING.md" \
  "${REPO_ROOT}/GLOSSARY.md" \
  "${REPO_ROOT}/Makefile" \
  "${REPO_ROOT}/manifests/" \
  "${REPO_ROOT}/docs/" \
  "${REPO_ROOT}/hack/"
pass "Zero banned cluster/project names or internal terms found."

log "Step 3: Checking Markdown relative links and Mermaid diagram syntax..."
python3 - "${REPO_ROOT}" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
md_files = [
    root / "README.md",
    root / "BLOG-01-STARTUP-BOOST.md",
    root / "BLOG-02-VPA-HPA-RIGHTSIZING.md",
    root / "TROUBLESHOOTING.md",
    root / "GLOSSARY.md",
] + list((root / "docs").rglob("*.md"))

link_re = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
for md in md_files:
    text = md.read_text(encoding="utf-8")
    for m in link_re.finditer(text):
        target = m.group(1).strip()
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        path_part = target.split("#", 1)[0]
        if not path_part:
            continue
        resolved = (md.parent / path_part).resolve()
        if not resolved.exists():
            raise SystemExit(f"Broken relative link in {md.relative_to(root)}: {target} -> {resolved}")

for doc_name in ("README.md", "BLOG-01-STARTUP-BOOST.md", "BLOG-02-VPA-HPA-RIGHTSIZING.md"):
    text = (root / doc_name).read_text(encoding="utf-8")
    assert "```mermaid" in text, f"Expected at least one Mermaid diagram in {doc_name}"
PY
pass "All Markdown relative links and Mermaid blocks verified."

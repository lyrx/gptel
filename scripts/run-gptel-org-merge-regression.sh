#!/usr/bin/env bash
# Compare gptel-org system-prompt merge: gptel-org.el before merge-system-message
# must fail the integration test; the current working-tree file must pass.
#
# Usage (from repo root):
#   ./scripts/run-gptel-org-merge-regression.sh
#
# Environment:
#   EMACS   Emacs binary (default: GPTEL_EMACS, else ~/git/clones/emacs/src/emacs, else `emacs`)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

resolve_emacs() {
  if [[ -n "${EMACS:-}" && -x "$EMACS" ]]; then
    printf '%s' "$EMACS"
    return
  fi
  if [[ -n "${GPTEL_EMACS:-}" && -x "$GPTEL_EMACS" ]]; then
    printf '%s' "$GPTEL_EMACS"
    return
  fi
  local u="$HOME/git/clones/emacs/src/emacs"
  if [[ -x "$u" ]]; then
    printf '%s' "$u"
    return
  fi
  command -v emacs
}

EMACS="$(resolve_emacs)"
TEST=( -Q --batch -L "$ROOT" -l "$ROOT/scripts/gptel-org-merge-tests.el"
       -f gptel-org-merge-tests-run )

run_tests() {
  "$EMACS" "${TEST[@]}" 2>&1
}

MERGE_INTRO=$(git log --reverse --format=%H -S 'defun gptel-org--merge-system-message' -- gptel-org.el 2>/dev/null | sed -n '1p')
if [[ -z "$MERGE_INTRO" ]]; then
  echo "ERROR: no commit introducing gptel-org--merge-system-message found (pickaxe)." >&2
  exit 1
fi
PREV_ORG=$(git rev-parse "${MERGE_INTRO}^")
BACKUP=$(mktemp)
cp "$ROOT/gptel-org.el" "$BACKUP"

cleanup() {
  rm -f "$ROOT/gptel-org.elc"
  if [[ -f "$BACKUP" ]]; then
    cp "$BACKUP" "$ROOT/gptel-org.el"
    rm -f "$BACKUP"
  fi
}

trap cleanup EXIT

echo "== Emacs: $EMACS"
echo "== Commit that introduced gptel-org--merge-system-message: $MERGE_INTRO"
echo "== gptel-org.el revision before that (regression \"old\"): $PREV_ORG"
echo "== Working tree backup: $BACKUP"
rm -f "$ROOT/gptel-org.elc"

echo "== Checking out gptel-org.el from before merge-system-message"
git checkout "$PREV_ORG" -- gptel-org.el

set +e
out_parent="$(run_tests)"
parent_exit=$?
set -e
printf '%s\n' "$out_parent"
if [[ "$parent_exit" -eq 0 ]]; then
  echo "ERROR: expected tests to FAIL on parent gptel-org.el (non-zero exit)." >&2
  exit 1
fi
echo "OK: parent gptel-org.el failed tests (exit $parent_exit), as expected."

echo "== Restoring working-tree gptel-org.el (must pass)"
cp "$BACKUP" "$ROOT/gptel-org.el"
rm -f "$ROOT/gptel-org.elc"

set +e
out_fix="$(run_tests)"
fix_exit=$?
set -e
printf '%s\n' "$out_fix"
if [[ "$fix_exit" -ne 0 ]]; then
  echo "ERROR: expected tests to PASS on working-tree gptel-org.el." >&2
  exit 1
fi
echo "OK: working-tree gptel-org.el passed all tests (exit 0)."

trap - EXIT
rm -f "$ROOT/gptel-org.elc"
echo "== Done."

#!/usr/bin/env bash
# Compare gptel-org system-prompt merge: the version of gptel-org.el from the
# parent of the last commit that touched the file must fail the integration
# test; the file at the current checkout must pass.  (Using plain HEAD~1 is
# wrong once follow-up commits only change scripts or docs.)
#
# Usage (from anywhere):
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

START_HEAD=$(git rev-parse HEAD)
MERGE_INTRO=$(git log -1 --format=%H -S 'defun gptel-org--merge-system-message' -- gptel-org.el)
if [[ -z "$MERGE_INTRO" ]]; then
  echo "ERROR: no commit introducing gptel-org--merge-system-message found (pickaxe)." >&2
  exit 1
fi
PREV_ORG=$(git rev-parse "${MERGE_INTRO}^")

cleanup() {
  rm -f "$ROOT/gptel-org.elc"
  if git rev-parse "$START_HEAD" >/dev/null 2>&1; then
    git checkout "$START_HEAD" -- gptel-org.el 2>/dev/null || true
  fi
}

trap cleanup EXIT

echo "== Emacs: $EMACS"
echo "== Restore target (checkout): $START_HEAD"
echo "== Commit that introduced gptel-org--merge-system-message: $MERGE_INTRO"
echo "== gptel-org.el revision before that (regression \"old\"): $PREV_ORG"
echo "== Removing gptel-org.elc so .el is not shadowed by stale bytecode"
rm -f "$ROOT/gptel-org.elc"

echo "== Checking out gptel-org.el from before merge-system-message was added"
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

echo "== Restoring gptel-org.el from $START_HEAD"
git checkout "$START_HEAD" -- gptel-org.el
rm -f "$ROOT/gptel-org.elc"

set +e
out_fix="$(run_tests)"
fix_exit=$?
set -e
printf '%s\n' "$out_fix"
if [[ "$fix_exit" -ne 0 ]]; then
  echo "ERROR: expected tests to PASS on fixed gptel-org.el." >&2
  exit 1
fi
echo "OK: fixed gptel-org.el passed all tests (exit 0)."

trap - EXIT
cleanup
echo "== Done."

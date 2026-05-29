#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMACS="${EMACS:-/home/alex/git/clones/emacs/src/emacs}"
# Recompile the files the tests exercise so stale .elc can never mask a
# regression.  load-prefer-newer is an extra safety net for any other .elc.
rm -f "$ROOT/gptel-org.elc" "$ROOT/gptel-rewrite.elc"
"$EMACS" --batch -L "$ROOT" -f batch-byte-compile \
  "$ROOT/gptel-org.el" "$ROOT/gptel-rewrite.el" >/dev/null 2>&1 || true
exec "$EMACS" --batch \
  --eval "(setq load-prefer-newer t)" \
  -L "$ROOT" \
  -l "$ROOT/scripts/gptel-org-system-section-tests.el" \
  -f gptel-org-system-section-test-run

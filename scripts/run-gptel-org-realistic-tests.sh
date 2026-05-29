#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMACS="${EMACS:-/home/alex/git/clones/emacs/src/emacs}"
# Recompile the exercised file so a stale .elc can never mask a regression.
rm -f "$ROOT/gptel-org.elc"
"$EMACS" --batch -L "$ROOT" -f batch-byte-compile "$ROOT/gptel-org.el" \
  >/dev/null 2>&1 || true
exec "$EMACS" --batch -Q \
  --eval "(setq load-prefer-newer t)" \
  -L "$ROOT" \
  -l "$ROOT/scripts/gptel-org-realistic-tests.el" \
  -f gptel-org-realistic-tests-run

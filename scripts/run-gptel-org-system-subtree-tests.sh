#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMACS="${EMACS:-/home/alex/git/clones/emacs/src/emacs}"
rm -f "$ROOT/gptel-org.elc"
"$EMACS" --batch -L "$ROOT" -f batch-byte-compile "$ROOT/gptel-org.el" >/dev/null
exec "$EMACS" --batch \
  -L "$ROOT" \
  -l "$ROOT/scripts/gptel-org-system-subtree-tests.el" \
  -f gptel-org-system-subtree-test-run

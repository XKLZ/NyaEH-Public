#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-run}" in
  --verify|verify) exec "$ROOT_DIR/script/verify.sh" --startup-only ;;
  *) exec python3 "$ROOT_DIR/script/testing/verify.py" dev -- "${1:-run}" ;;
esac

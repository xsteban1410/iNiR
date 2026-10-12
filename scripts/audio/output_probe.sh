#!/usr/bin/env bash
# Runs the output probe with iNiR's Python environment, where NumPy lives.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${INIR_VENV:-}" ]]; then
    _ii_venv="$(eval echo "$INIR_VENV")"
elif [[ -n "${ILLOGICAL_IMPULSE_VIRTUAL_ENV:-}" ]]; then
    _ii_venv="$(eval echo "$ILLOGICAL_IMPULSE_VIRTUAL_ENV")"
else
    _ii_venv="$HOME/.local/state/quickshell/.venv"
fi
_python="$_ii_venv/bin/python3"
[[ -x "$_python" ]] || _python="python3"
exec "$_python" "$SCRIPT_DIR/output_probe.py" "$@"

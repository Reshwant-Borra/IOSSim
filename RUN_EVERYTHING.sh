#!/usr/bin/env bash
# RUN_EVERYTHING.sh — Launch iOS Location Sim on macOS (backend + frontend)
# Usage:
#   ./RUN_EVERYTHING.sh            # stable mode (default)
#   ./RUN_EVERYTHING.sh experimental

set -euo pipefail

MODE="${1:-stable}"
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$PROJECT_ROOT/backend"
FRONTEND="$PROJECT_ROOT/frontend"
VENV_PYTHON="$BACKEND/.venv/bin/python"

if [[ "$MODE" != "stable" && "$MODE" != "experimental" ]]; then
  echo "Usage: $0 [stable|experimental]"
  exit 1
fi

if [[ "$MODE" == "experimental" ]]; then
  BACKEND_ENV="export IOS_SIM_ENABLE_EXPERIMENTAL=1 IOS_SIM_ENABLE_DRIVE_MODE=1;"
  FRONTEND_ENV="export VITE_ENABLE_EXPERIMENTAL_FEATURES=1 VITE_ENABLE_DRIVE_MODE=1;"
  echo "[MODE] Experimental launch: Drive Mode and experimental UI enabled."
else
  BACKEND_ENV="export IOS_SIM_ENABLE_EXPERIMENTAL=0;"
  FRONTEND_ENV="export VITE_ENABLE_EXPERIMENTAL_FEATURES=0;"
  echo "[MODE] Stable launch: experimental features disabled."
fi

for f in "$BACKEND/main.py" "$FRONTEND/package.json" "$BACKEND/requirements.txt"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: Missing required file: $f"
    exit 1
  fi
done
echo "[OK] Project structure verified."

if [[ ! -x "$VENV_PYTHON" ]]; then
  echo "[...] Creating Python virtual environment..."
  PYTHON_CREATE=""
  for candidate in python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
      PYTHON_CREATE="$candidate"
      break
    fi
  done
  if [[ -z "$PYTHON_CREATE" ]]; then
    echo "ERROR: Python 3.11+ required. On macOS: brew install python@3.13"
    exit 1
  fi
  "$PYTHON_CREATE" -m venv "$BACKEND/.venv"
fi

echo "[...] Installing backend requirements..."
"$VENV_PYTHON" -m pip install -q -r "$BACKEND/requirements.txt"
echo "[OK] Backend requirements installed."

if [[ ! -d "$FRONTEND/node_modules" ]]; then
  echo "[...] Installing frontend dependencies..."
  (cd "$FRONTEND" && npm install)
  echo "[OK] Frontend dependencies installed."
else
  echo "[OK] Frontend node_modules already present, skipping install."
fi

BACKEND_CMD="${BACKEND_ENV} cd '$BACKEND' && sudo -E '$VENV_PYTHON' -m uvicorn main:app --host 127.0.0.1 --port 8765 --reload"
FRONTEND_CMD="${FRONTEND_ENV} cd '$FRONTEND' && npm run dev"

echo "[...] Starting backend (sudo) on http://127.0.0.1:8765 ..."
osascript -e "tell application \"Terminal\" to do script \"$BACKEND_CMD\""

echo "[...] Starting frontend on http://localhost:5173 ..."
osascript -e "tell application \"Terminal\" to do script \"$FRONTEND_CMD\""

echo "[...] Waiting 5 seconds for services to start..."
sleep 5
open "http://localhost:5173"

echo ""
echo "============================================="
echo "  iOS Location Sim is running!"
echo "  Mode     : $MODE"
echo "  Frontend : http://localhost:5173"
echo "  Backend  : http://127.0.0.1:8765"
echo "  Docs     : http://127.0.0.1:8765/docs"
echo "============================================="
echo ""
echo "The backend window will ask for your Mac password (sudo)."
echo "Keep both Terminal windows open while using the app."

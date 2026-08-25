#!/usr/bin/env bash
# RUN_EVERYTHING.sh — Launch iOS Location Sim on macOS (backend + frontend)
# Usage:
#   ./RUN_EVERYTHING.sh            # stable mode (default)
#   ./RUN_EVERYTHING.sh experimental
#   ./RUN_EVERYTHING.sh drive-testing
#   ./RUN_EVERYTHING.sh wireless-testing
#   ./RUN_EVERYTHING.sh stop       # stop IOSSim backend/frontend/location processes

set -euo pipefail

MODE="${1:-stable}"
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
BACKEND="$PROJECT_ROOT/backend"
FRONTEND="$PROJECT_ROOT/frontend"
VENV_PYTHON="$BACKEND/.venv/bin/python"

if [[ "$MODE" != "stable" && "$MODE" != "experimental" && "$MODE" != "drive-testing" && "$MODE" != "wireless-testing" && "$MODE" != "stop" ]]; then
  echo "Usage: $0 [stable|experimental|drive-testing|wireless-testing|stop]"
  exit 1
fi

stop_iossim_processes() {
  echo "[...] Stopping existing IOSSim backend/frontend/location processes..."
  local pids=""
  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -nP -iTCP:8765 -sTCP:LISTEN -t 2>/dev/null || true)"
    pids="$pids $(lsof -nP -iTCP:5173 -sTCP:LISTEN -t 2>/dev/null || true)"
  fi
  if command -v pgrep >/dev/null 2>&1; then
    pids="$pids $(pgrep -f "$PROJECT_ROOT/.+uvicorn|uvicorn main:app|npm run dev|vite .*5173" 2>/dev/null || true)"
    pids="$pids $(pgrep -f "pymobiledevice3 .*simulate-location" 2>/dev/null || true)"
  fi
  pids="$(printf "%s\n" $pids 2>/dev/null | awk 'NF && $1 != "'"$$"'" {print $1}' | sort -u | tr '\n' ' ')"
  if [[ -z "${pids// /}" ]]; then
    echo "[OK] No IOSSim processes found."
    return 0
  fi
  kill $pids 2>/dev/null || true
  sleep 1
  local remaining=""
  for pid in $pids; do
    if ps -p "$pid" >/dev/null 2>&1; then
      remaining="$remaining $pid"
    fi
  done
  if [[ -n "${remaining// /}" ]]; then
    echo "[...] Some processes need administrator privileges:$remaining"
    osascript -e "do shell script \"kill -TERM $remaining 2>/dev/null || true\" with administrator privileges" >/dev/null 2>&1 || true
    sleep 1
  fi
  echo "[OK] Stop request complete."
}

repair_data_permissions() {
  mkdir -p "$BACKEND/data"
  if [[ -n "${SUDO_UID:-}" ]]; then
    sudo chown -R "$SUDO_UID:${SUDO_GID:-$(id -g)}" "$BACKEND/data" 2>/dev/null || true
  else
    chown -R "$(id -u):$(id -g)" "$BACKEND/data" 2>/dev/null || true
  fi
}

if [[ "$MODE" == "stop" ]]; then
  stop_iossim_processes
  exit 0
fi

if [[ "$MODE" == "drive-testing" ]]; then
  BACKEND_ENV="export IOS_SIM_ENABLE_EXPERIMENTAL=1; export IOS_SIM_ENABLE_DRIVE_TESTING=1;"
  FRONTEND_ENV="export VITE_ENABLE_EXPERIMENTAL_FEATURES=1; export VITE_ENABLE_DRIVE_TESTING=1;"
  echo "[MODE] Drive Testing Lab launch: dedicated experimental flags enabled."
elif [[ "$MODE" == "wireless-testing" ]]; then
  BACKEND_ENV="export IOS_SIM_ENABLE_EXPERIMENTAL=1; export IOS_SIM_ENABLE_WIRELESS_TESTING=1;"
  FRONTEND_ENV="export VITE_ENABLE_EXPERIMENTAL_FEATURES=1; export VITE_ENABLE_WIRELESS_TESTING=1;"
  echo "[MODE] Wireless Testing Lab launch: dedicated experimental flags enabled."
elif [[ "$MODE" == "experimental" ]]; then
  BACKEND_ENV="export IOS_SIM_ENABLE_EXPERIMENTAL=1;"
  FRONTEND_ENV="export VITE_ENABLE_EXPERIMENTAL_FEATURES=1;"
  echo "[MODE] Experimental launch: Lock & Unplug and other experimental features enabled."
else
  BACKEND_ENV=""
  FRONTEND_ENV=""
  echo "[MODE] Stable launch."
fi

for f in "$BACKEND/main.py" "$FRONTEND/package.json" "$BACKEND/requirements.txt"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: Missing required file: $f"
    exit 1
  fi
done
echo "[OK] Project structure verified."

stop_iossim_processes
repair_data_permissions

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

if [[ "$MODE" == "drive-testing" || "$MODE" == "wireless-testing" ]]; then
  RELOAD_ARG=""
else
  RELOAD_ARG="--reload"
fi
BACKEND_CMD="${BACKEND_ENV} cd '$BACKEND' && sudo -E '$VENV_PYTHON' -m uvicorn main:app --host 127.0.0.1 --port 8765 $RELOAD_ARG"
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
echo "Stop everything later with: ./RUN_EVERYTHING.sh stop"

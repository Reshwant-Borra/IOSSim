@echo off
echo iOS Location Sim — Starting...
echo.

cd /d "%~dp0"

echo [1/2] Starting backend (needs admin for iOS 17+ tunnel)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd -Verb RunAs -ArgumentList '/k cd /d ""%CD%\backend"" && pip install -r requirements.txt -q && python -m uvicorn main:app --host 0.0.0.0 --port 8765 --reload'"

timeout /t 3 /nobreak >nul

echo [2/2] Starting frontend dev server...
start "iOS-Sim-Frontend" cmd /k "cd frontend && npm install --silent && npm run dev"

timeout /t 4 /nobreak >nul

echo.
echo Opening browser at http://localhost:5173
start http://localhost:5173

echo.
echo Both servers running. Close the two console windows to stop.
pause

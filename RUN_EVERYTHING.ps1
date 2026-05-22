# RUN_EVERYTHING.ps1 — Launch iOS Location Sim (backend + tunnel + frontend)

$ProjectRoot = "C:\Users\reshw\Desktop\ios-location-sim"
$Backend     = "$ProjectRoot\backend"
$Frontend    = "$ProjectRoot\frontend"

# ── Verify required files ────────────────────────────────────────────────────
$checks = @("$Backend\main.py", "$Frontend\package.json", "$Backend\requirements.txt")
foreach ($f in $checks) {
    if (-not (Test-Path $f)) {
        Write-Error "Missing required file: $f"
        exit 1
    }
}
Write-Host "[OK] Project structure verified." -ForegroundColor Green

# ── Install backend requirements ─────────────────────────────────────────────
Write-Host "[...] Installing backend requirements..." -ForegroundColor Cyan
pip install -r "$Backend\requirements.txt"
Write-Host "[OK] Backend requirements installed." -ForegroundColor Green

# ── Install frontend dependencies (only if missing) ──────────────────────────
if (-not (Test-Path "$Frontend\node_modules")) {
    Write-Host "[...] Installing frontend dependencies..." -ForegroundColor Cyan
    Push-Location $Frontend
    npm install
    Pop-Location
    Write-Host "[OK] Frontend dependencies installed." -ForegroundColor Green
} else {
    Write-Host "[OK] Frontend node_modules already present, skipping install." -ForegroundColor Green
}

# ── Start backend as admin ────────────────────────────────────────────────────
# The backend must own the tunnel process so it can store the parsed RSD address.
Write-Host "[...] Starting backend as admin on http://127.0.0.1:8765 ..." -ForegroundColor Cyan
Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "cd '$Backend'; python -m uvicorn main:app --host 127.0.0.1 --port 8765 --reload; Read-Host 'Press Enter to close'"

# ── Start frontend ────────────────────────────────────────────────────────────
Write-Host "[...] Starting frontend on http://localhost:5173 ..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "cd '$Frontend'; npm run dev; Read-Host 'Press Enter to close'"

# ── Open browser after short delay ───────────────────────────────────────────
Write-Host "[...] Waiting 5 seconds for services to start..." -ForegroundColor Cyan
Start-Sleep -Seconds 5
Start-Process "http://localhost:5173"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host "  iOS Location Sim is running!" -ForegroundColor Yellow
Write-Host "  Frontend : http://localhost:5173" -ForegroundColor Yellow
Write-Host "  Backend  : http://127.0.0.1:8765" -ForegroundColor Yellow
Write-Host "  Docs     : http://127.0.0.1:8765/docs" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow

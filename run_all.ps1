$ProjectRoot = "C:\Users\reshw\Desktop\ios-location-sim"

if (-not (Test-Path "$ProjectRoot\backend\main.py")) {
    Write-Host "ERROR: backend\main.py not found" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path "$ProjectRoot\frontend\package.json")) {
    Write-Host "ERROR: frontend\package.json not found" -ForegroundColor Red
    exit 1
}

if (Test-Path "$ProjectRoot\backend\requirements.txt") {
    pip install -r "$ProjectRoot\backend\requirements.txt" -q
}

if (-not (Test-Path "$ProjectRoot\frontend\node_modules")) {
    npm install --prefix "$ProjectRoot\frontend"
}

Start-Process powershell -Verb RunAs -ArgumentList "-NoExit", "-Command", "Set-Location '$ProjectRoot\backend'; python -m uvicorn main:app --host 127.0.0.1 --port 8765 --reload"

Start-Process powershell -ArgumentList "-NoExit", "-Command", "Set-Location '$ProjectRoot\frontend'; npm run dev"

Start-Sleep -Seconds 4

Start-Process "http://localhost:5173"

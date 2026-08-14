param(
    [ValidateSet("stable", "experimental", "drive-testing", "wireless-testing")]
    [string]$Mode = "stable"
)

# RUN_EVERYTHING.ps1 - Launch iOS Location Sim (backend + tunnel + frontend)
# Stable mode is the default. Experimental mode enables Drive Mode and other
# explicitly gated test workflows for this session only.

$ProjectRoot = $PSScriptRoot
$Backend     = "$ProjectRoot\backend"
$Frontend    = "$ProjectRoot\frontend"
$Experimental = $Mode -eq "experimental"
$DriveTesting = $Mode -eq "drive-testing"
$WirelessTesting = $Mode -eq "wireless-testing"

if ($DriveTesting) {
    $BackendEnv = "`$env:IOS_SIM_ENABLE_EXPERIMENTAL='1'; `$env:IOS_SIM_ENABLE_DRIVE_TESTING='1'; "
    $FrontendEnv = "`$env:VITE_ENABLE_EXPERIMENTAL_FEATURES='1'; `$env:VITE_ENABLE_DRIVE_TESTING='1'; "
    Write-Host "[MODE] Drive Testing Lab launch: dedicated experimental flags enabled." -ForegroundColor Yellow
} elseif ($WirelessTesting) {
    $BackendEnv = "`$env:IOS_SIM_ENABLE_EXPERIMENTAL='1'; `$env:IOS_SIM_ENABLE_WIRELESS_TESTING='1'; "
    $FrontendEnv = "`$env:VITE_ENABLE_EXPERIMENTAL_FEATURES='1'; `$env:VITE_ENABLE_WIRELESS_TESTING='1'; "
    Write-Host "[MODE] Wireless Testing Lab launch: dedicated experimental flags enabled." -ForegroundColor Yellow
} elseif ($Experimental) {
    $BackendEnv = "`$env:IOS_SIM_ENABLE_EXPERIMENTAL='1'; "
    $FrontendEnv = "`$env:VITE_ENABLE_EXPERIMENTAL_FEATURES='1'; "
    Write-Host "[MODE] Experimental launch: Lock & Unplug and other experimental features enabled." -ForegroundColor Yellow
} else {
    $BackendEnv = ""
    $FrontendEnv = ""
    Write-Host "[MODE] Stable launch." -ForegroundColor Green
}

# Verify required files
$checks = @("$Backend\main.py", "$Frontend\package.json", "$Backend\requirements.txt")
foreach ($f in $checks) {
    if (-not (Test-Path $f)) {
        Write-Error "Missing required file: $f"
        exit 1
    }
}
Write-Host "[OK] Project structure verified." -ForegroundColor Green

# Refuse to take over an unrelated listener on the backend port.
$listener = Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
    $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    $owner = "unknown"
    try {
        $ownerInfo = Invoke-CimMethod -InputObject (Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)") -MethodName GetOwner -ErrorAction Stop
        if ($ownerInfo.User) { $owner = "$($ownerInfo.Domain)\$($ownerInfo.User)" }
    } catch {}
    Write-Host "ERROR: Port 8765 is already in use." -ForegroundColor Red
    Write-Host "  PID          : $($listener.OwningProcess)"
    Write-Host "  Process name : $($process.ProcessName)"
    Write-Host "  User         : $owner"
    Write-Host "  Inspect with : Get-Process -Id $($listener.OwningProcess)"
    exit 1
}

$VenvPython = Join-Path $Backend ".venv\Scripts\python.exe"
if (Test-Path $VenvPython) {
    $Python = $VenvPython
} else {
    $PythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if (-not $PythonCommand) {
        Write-Error "Python 3.11+ was not found and backend\.venv does not exist."
        exit 1
    }
    $Python = $PythonCommand.Source
}

# Install backend requirements
Write-Host "[...] Installing backend requirements..." -ForegroundColor Cyan
& $Python -m pip install -r "$Backend\requirements.txt"
Write-Host "[OK] Backend requirements installed." -ForegroundColor Green

# Install frontend dependencies only if missing
if (-not (Test-Path "$Frontend\node_modules")) {
    Write-Host "[...] Installing frontend dependencies..." -ForegroundColor Cyan
    Push-Location $Frontend
    npm install
    Pop-Location
    Write-Host "[OK] Frontend dependencies installed." -ForegroundColor Green
} else {
    Write-Host "[OK] Frontend node_modules already present, skipping install." -ForegroundColor Green
}

# Start backend as admin. The backend must own the tunnel process so it can
# store the parsed RSD address.
Write-Host "[...] Starting backend as admin on http://127.0.0.1:8765 ..." -ForegroundColor Cyan
$ReloadArg = if ($DriveTesting -or $WirelessTesting) { "" } else { " --reload" }
Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$BackendEnv cd '$Backend'; & '$Python' -m uvicorn main:app --host 127.0.0.1 --port 8765$ReloadArg; Read-Host 'Press Enter to close'"

# Start frontend
Write-Host "[...] Starting frontend on http://localhost:5173 ..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$FrontendEnv cd '$Frontend'; npm run dev; Read-Host 'Press Enter to close'"

# Open browser after short delay
Write-Host "[...] Waiting 5 seconds for services to start..." -ForegroundColor Cyan
Start-Sleep -Seconds 5
Start-Process "http://localhost:5173"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host "  iOS Location Sim is running!" -ForegroundColor Yellow
Write-Host "  Mode     : $Mode" -ForegroundColor Yellow
Write-Host "  Frontend : http://localhost:5173" -ForegroundColor Yellow
Write-Host "  Backend  : http://127.0.0.1:8765" -ForegroundColor Yellow
Write-Host "  Docs     : http://127.0.0.1:8765/docs" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow

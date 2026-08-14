# Windows Setup

Run PowerShell as Administrator:

```powershell
cd C:\path\to\IOSSim
.\RUN_EVERYTHING.ps1 -Mode drive-testing
```

The launcher prefers `backend\.venv\Scripts\python.exe`, checks port `8765`, starts the backend elevated, and does not use reload in Drive Testing mode. Standalone iTunes/Apple Mobile Device Support is required for USB support on Windows.

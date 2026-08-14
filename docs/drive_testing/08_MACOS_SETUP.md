# macOS Setup

```bash
cd ~/IOSSim
chmod +x RUN_EVERYTHING.sh
./RUN_EVERYTHING.sh drive-testing
```

The launcher uses `backend/.venv/bin/python`, installs requirements, checks port `8765`, starts the backend with `sudo`, starts Vite, and omits uvicorn reload in Drive Testing mode.

Direct validation:

```bash
cd ~/IOSSim/backend
source .venv/bin/activate
python -m pymobiledevice3 usbmux list
python -m pymobiledevice3 amfi developer-mode-status
python -m pymobiledevice3 amfi reveal-developer-mode
```

Without activation:

```bash
~/IOSSim/backend/.venv/bin/python -m pymobiledevice3 usbmux list
```

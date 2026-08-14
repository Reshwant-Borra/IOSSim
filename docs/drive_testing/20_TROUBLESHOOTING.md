# Troubleshooting

## macOS checks

```bash
cd ~/IOSSim/backend
source .venv/bin/activate
python -m pymobiledevice3 usbmux list
python -m pymobiledevice3 amfi developer-mode-status
python -m pymobiledevice3 amfi reveal-developer-mode
```

Direct virtual-environment use:

```bash
~/IOSSim/backend/.venv/bin/python -m pymobiledevice3 usbmux list
```

## Common errors

- `zsh: command not found: python`: activate `backend/.venv` or call its Python directly.
- `No module named pymobiledevice3`: install `backend/requirements.txt` with the same interpreter used to launch uvicorn.
- `Device is not connected`: unlock, reconnect USB, accept trust, and run `usbmux list`.
- Developer Mode not visible: run `amfi reveal-developer-mode`, then check Privacy & Security again.
- Trust This Computer prompt missing: reconnect while unlocked; reset Location & Privacy only if appropriate for the authorized device.
- Tunnel not active: run the backend elevated and initialize again.
- Address already in use: inspect port `8765`; do not kill an unrelated process automatically.

```bash
sudo lsof -nP -iTCP:8765 -sTCP:LISTEN
ps -fp <PID>
sudo kill <PID>
```

Use `sudo kill -9 <PID>` only if normal termination fails and the process is confirmed to belong to this IOSSim session.

- GPX pause unavailable: use Stop or Emergency Stop; installed pymobiledevice3 does not expose confirmed GPX pause.
- Reset failure: do not ignore it. Reconnect/initialize the device and run Reset GPS again.

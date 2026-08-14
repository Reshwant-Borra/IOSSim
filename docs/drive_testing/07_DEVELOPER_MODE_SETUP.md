# Developer Mode Setup

On the iPhone, open:

```text
Settings > Privacy & Security > Developer Mode
```

Turn Developer Mode on, follow the restart prompt, unlock the phone, and confirm. The lab provides copy buttons for:

```bash
python -m pymobiledevice3 amfi developer-mode-status
python -m pymobiledevice3 amfi reveal-developer-mode
```

The first trust prompt still requires physical interaction on the authorized phone.

# 16 iPhone Remote Control UI

## Architecture

```text
Safari on iPhone
  -> IOSSim web UI
Mac/PC backend
  -> pymobiledevice3 / RSD / DVT
same iPhone
```

This is realistic and distinct from iPhone-only control. The phone is only the browser; the host still performs privileged device control.

## Current repo constraints

- `frontend/vite.config.ts` proxies `/api` to `http://localhost:8765`.
- Vite dev server defaults to localhost unless launched with `--host`.
- FastAPI CORS currently allows only:

  ```text
  http://localhost:5173
  http://127.0.0.1:5173
  ```

- README manual command shows backend can bind `0.0.0.0`, but macOS launcher binds backend to `127.0.0.1`.
- No API authentication exists.

## Answers

| Question | Answer |
|---|---|
| Can frontend bind to LAN IP instead of localhost? | Yes with Vite `--host 0.0.0.0` or production static serving. |
| Can FastAPI safely expose UI/API on private LAN? | Only after adding auth, CORS/host controls, and LAN/VPN scoping. Current unauthenticated API should stay localhost. |
| Can authentication be added? | Yes. Use local password or device-pair code at minimum; token/session auth for cloud. |
| Can Tailscale provide private access? | Yes. Tailscale-only is preferable to public LAN/Internet exposure. |
| Can the iPhone control its own simulation indirectly through the Mac? | Yes. Safari commands the Mac; the Mac commands the same iPhone. |
| Can the UI work well on mobile? | Current UI is desktop/sidebar-heavy. It would need responsive layout, larger controls, safe-area handling, loading/error states, and explicit “you are controlling this device” status. |

## Recommended safe experiment

No code change required for first LAN test if using production static serving or temporary dev flags:

```text
Backend: bind to 0.0.0.0 only on trusted LAN/VPN.
Frontend: run Vite with --host 0.0.0.0 or serve built frontend from FastAPI.
iPhone Safari: open http://MAC_LAN_IP:5173 or backend-served UI.
```

Do not expose the current API on the public Internet.


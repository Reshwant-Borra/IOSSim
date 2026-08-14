# 03 usbmuxd and libimobiledevice

## What usbmuxd is useful for

`usbmuxd` multiplexes host connections to device services over the iPhone USB link. It exposes a local daemon/socket to host tools; those tools then connect to numbered ports on the device. This is foundational for pairing, lockdown, AFC, syslog, app management, and older developer services.

Sources: Arch [usbmuxd(8)](https://man.archlinux.org/man/usbmuxd.8.en), libimobiledevice [project site](https://libimobiledevice.org/).

## Wireless lockdown / Wi-Fi Sync

libimobiledevice documents network support for devices with Wi-Fi Sync enabled. Apple/Xcode troubleshooting also identifies port `62078` as the network-device communication port. Older tools such as `idevice_id -n` target this category of Wi-Fi lockdown/usbmux communication.

Limits:

- This is not the same as iOS 17+ CoreDevice/RSD developer-service transport.
- It may list/connect for basic lockdown services while DVT still requires a trusted RSD tunnel.
- Open-source network support has had platform/version reliability issues. libusbmuxd issue #88 shows older Wi-Fi discovery/port 62078 problems.

## Remote usbmuxd

pymobiledevice3 supports a remote usbmux daemon address:

```text
--usbmux HOST:PORT
PYMOBILEDEVICE3_USBMUX
USBMUXD_SOCKET_ADDRESS
```

This means IOSSim could theoretically run on machine A while connecting to a usbmuxd-compatible daemon on machine B near the phone. That helps only if the remote daemon can expose the required device services and if iOS 17+ tunnel setup can be driven successfully through that forwarded path.

## Answers

| Question | Answer |
|---|---|
| Is wireless lockdown still supported? | Yes at a broad Apple/libimobiledevice level for Wi-Fi Sync/network devices, but reliability and iOS 17+ developer-service applicability are separate questions. |
| Can pair records be reused? | Yes, pair records are the trust basis. Reuse across hosts is sensitive and risky; copying them expands attack surface. |
| Can usbmux protocol itself be forwarded over TCP? | Yes. Tools like usbfluxd and `socat tcp-listen:... unix-connect:/var/run/usbmuxd` demonstrate this pattern. |
| Can a remote `usbmuxd` server be accessed? | Yes in pymobiledevice3 via `--usbmux HOST:PORT` or env vars. |
| Does that help with iOS 17+/26 developer services? | Possibly. It can get IOSSim to the remote lockdown/usbmux layer, but DVT still requires CoreDevice/RSD tunnel creation and privileges on whichever host creates the tunnel. |
| Could IOSSim connect to a remote Mac's usbmuxd from another machine? | Technically possible through socket forwarding/private VPN. Security-sensitive and not Apple-supported. |
| Could a tiny local bridge expose usbmuxd securely over private VPN? | Yes, with strict authentication/network controls. A better pattern is often to run the DVT bridge locally and expose only a narrow HTTPS/WebSocket command API. |
| Would that preserve DVT access? | Unproven. For iOS 17+, DVT depends on a tunnel; forwarding usbmux alone is not enough unless tunnel setup and RSD reachability also work. |

## Practical conclusion

`usbmuxd` forwarding is a feasible remote-host building block, not the best end-user architecture. It exposes broad device-management capability. For IOSSim, a narrow local agent that owns usbmux/RSD/DVT and receives only authenticated location commands is safer.


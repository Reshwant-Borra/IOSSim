# 18 Architecture Decision Matrix

Scores: 1 = poor, 5 = strong. Compatibility with existing IOSSim emphasizes minimal code change.

| Rank | Architecture | Feas. | Cable-free | Mac-free | Reliability | Complexity | Cost | Security | iOS 26 | IOSSim fit | Effort | Summary |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | A. Current USB Mac/PC | 5 | 1 | 3 | 5 | 5 | 4 | 4 | 5 | 5 | 5 | Stable baseline |
| 2 | B. Initial USB pairing -> wireless Mac/iPhone | 4 | 4 | 2 | 3 | 3 | 4 | 3 | 4 | 4 | 3 | Best cable-free candidate; needs experiments |
| 3 | C. Wireless Mac + iPhone remote UI | 4 | 4 | 2 | 3 | 3 | 4 | 3 | 4 | 4 | 3 | Practical if Wi-Fi DVT works |
| 4 | E. Cloud UI + Mac bridge agent | 5 | 2-4 | 2 | 4 | 3 | 3 | 4 | 5 | 5 | 3 | Best hosted-control model |
| 5 | F. Headless Mac mini bridge | 5 | 2-4 | 1 | 5 | 4 | 3 | 4 | 5 | 5 | 4 | Most reliable local host |
| 6 | G. Linux bridge | 3 | 2-4 | 5 | 3 | 3 | 5 | 3 | 3 | 3 | 3 | Mac-free host possible; validate RSD |
| 7 | H. Raspberry Pi USB relay | 3 | 1 | 5 | 3 | 3 | 5 | 3 | 3 | 2 | 3 | Small local bridge, not cable-free |
| 8 | I. USB-over-IP | 3 | 1 | 3 | 2 | 2 | 3 | 2 | 3 | 2 | 2 | Useful lab fallback, broad exposure |
| 9 | D. Mac at home + iPhone over VPN | 2 | 5 | 1 | 2 | 2 | 4 | 3 | 2 | 2 | 2 | Too many unproven network assumptions |
| 10 | J. External MFi GPS hardware | 4 | 5 | 5 | 4 | 3 | 2 | 4 | 4 | 1 | 2 | Good no-Mac path, different system |
| 11 | N. Jailbroken iPhone | 2 | 5 | 5 | 2 | 1 | 3 | 1 | 1 | 1 | 1 | Research-only for old/vulnerable devices |
| 12 | M. Sideloaded iPhone app | 1 | 5 | 5 | 2 | 3 | 4 | 3 | 4 | 1 | 2 | Cannot system-wide spoof stock iOS |
| 13 | L. iPhone-only Pythonista | 1 | 5 | 5 | 2 | 4 | 4 | 4 | 4 | 1 | 1 | Sandbox blocks needed services |
| 14 | K. iPhone-only App Store app | 1 | 5 | 5 | 4 | 5 | 5 | 5 | 5 | 1 | 1 | Not possible for system-wide override |

## Recommended sequence

1. Keep current USB path as the stable baseline.
2. Run wireless RSD/DVT experiments with pymobiledevice3.
3. If successful, add a feature-flagged wireless tunnel mode.
4. Separately, expose authenticated iPhone-friendly UI over LAN/Tailscale.
5. For hosted product direction, build cloud UI + local bridge agent.


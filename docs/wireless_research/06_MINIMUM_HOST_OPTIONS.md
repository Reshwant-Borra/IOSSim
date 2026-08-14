# 06 Minimum Host Options

## Key distinction

A Mac is required for Apple’s official Xcode UI and Device Hub. A Mac is not necessarily required for IOSSim’s current pymobiledevice3 DVT path: pymobiledevice3 runs on Windows, Linux, and macOS, and this repository already supports Windows. For iOS 17+/26, the hard requirement is a host that can pair with the phone and establish the RSD/CoreDevice tunnel.

## Comparison table

| Host | Pair with iPhone | Run pymobiledevice3 | Access developer services | Establish RSD | Run DVT location | Wireless operation | Headless | Cost | Complexity | Reliability |
|---|---|---|---|---|---|---|---|---:|---:|---:|
| Mac mini | Yes | Yes | Yes, plus Xcode fallback | Yes | Yes | Likely with Xcode/pmd3 | Yes | Medium | Low | High |
| Old MacBook | Yes | Yes | Yes | Yes | Yes | Likely | Yes-ish | Low | Low | Medium |
| Mac Studio | Yes | Yes | Yes | Yes | Yes | Likely | Yes | High | Low | High |
| Mac VM on Apple hardware | Maybe | Yes | Maybe | Maybe | Maybe | Unproven | Yes | Medium | High | Medium-low |
| Linux PC | Yes via libimobiledevice/pmd3 | Yes | Yes via pmd3, not Xcode | Likely but driver/version-sensitive | Likely | Wi-Fi unproven | Yes | Low | Medium | Medium |
| Windows PC | Yes with Apple Mobile Device Support | Yes | Yes via pmd3 | Confirmed for current repo USB/RSD path | Yes | Wi-Fi unproven; Bonjour issues reported | Yes | Low | Medium | Medium |
| Raspberry Pi | Yes via USB/libimobiledevice | Likely if Python deps build | Maybe | Unproven for modern RSD performance | Maybe | Unproven | Yes | Low | High | Low-medium |
| Cheap x86 mini PC | Yes | Yes | Likely | Likely | Likely | Unproven | Yes | Low | Medium | Medium |
| Cloud macOS VM / EC2 Mac / MacStadium | Not with nearby phone unless forwarded | Yes | Yes for simulators/builds; physical phone needs relay | Only through relay | Through relay | Not directly | Yes | High | Medium-high | Medium |
| GitHub Codespaces | No direct USB/device pairing | Maybe | No physical device channel | No | No | No | Yes | Low | High | Low |
| Docker host | Host-dependent | Maybe | Needs USB/network privileges | Host-dependent | Host-dependent | Host-dependent | Yes | Low | High | Low-medium |
| Home server near phone | Yes if USB host and deps | Yes | Likely | Likely | Likely | Unproven | Yes | Low-medium | Medium | Medium |

## Practical ranking for minimum local host

1. Headless Mac mini: best reliability and Xcode fallback.
2. Existing Windows PC: already works for stable USB/RSD in this repo; wireless needs experiments.
3. Linux x86 mini PC: plausible small bridge; less Xcode fallback.
4. Raspberry Pi: attractive size/cost, but modern RSD/tunnel and Python dependency performance need testing.
5. Cloud Mac alone: not enough unless the iPhone is also reachable through USB-over-IP/usbmux relay or wireless developer channel over routable network.

## Conclusion

The smallest realistic local component is not “no host”; it is a small local bridge running pymobiledevice3 and holding pairing material. The most reliable version is a headless Mac mini. The cheapest plausible version is a Linux mini PC or Raspberry Pi, but those must be experimentally validated on iOS 26.x.


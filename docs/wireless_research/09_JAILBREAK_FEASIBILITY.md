# 09 Jailbreak Feasibility

## Separate category

Jailbreak is technically relevant but should not be the default IOSSim architecture. It changes device security, compatibility, reliability, and support assumptions.

## Feasibility

| Question | Answer |
|---|---|
| Could a jailbroken device override system location locally? | Yes in principle. Tweaks can hook CoreLocation clients, `locationd`, or related APIs/daemons depending on jailbreak capability. |
| Which iOS versions are compatible? | Public mainstream tools are version/device constrained. Dopamine targets iOS 15/16 ranges. palera1n targets checkm8-vulnerable A8-A11 devices on iOS 15+ ranges, mostly old hardware. |
| Is iOS 26.x currently jailbreakable? | No public, reliable jailbreak for modern iOS 26.x iPhones was confirmed. Treat iOS 26.x modern-device jailbreak as not available. |
| Would it require persistent jailbreak state? | Yes. Semi-untethered/semi-tethered workflows usually require reactivation after reboot; some require a computer. |
| Could a local app control location? | Yes if a tweak/daemon exposes a control API to that app. |
| Could it run without a Mac after setup? | Possibly until reboot/resign/rejailbreak events. Depends on device/tool. |
| Security/reliability implications? | High risk: weaker device security, app incompatibility, update fragility, possible banking/MDM/app integrity failures, and higher support burden. |

## Tools/references

- Dopamine: rootless semi-untethered jailbreak for iOS 15/16 ranges, per [GitHub](https://github.com/opa334/dopamine) and [Dopamine site](https://ellekit.space/dopamine/).
- palera1n: checkm8-based jailbreak for A8-A11-class devices, per [palera1n site](https://palera.in/) and [compatibility chart](https://docs.palera.in/docs/reference/compatibility-chart/).
- Theos/MobileSubstrate/Substitute/ElleKit are tweak development/runtime categories that enable process injection on jailbroken systems. No exploit instructions are provided here.

## Verdict

Jailbreak can remove the Mac for some older/vulnerable devices, but it is not realistic for a stock iOS 26.x iPhone. For IOSSim’s target architecture, jailbreak is a research-only fallback, not a product path.


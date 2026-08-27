# Mirage Audit

Repository found: `https://github.com/xXWapixelXx/Mirage-updates`

Audited commit: `37adcf5b9c7ee67cae78ebafdb5aa7a1459175cb`

Type: public update manifest/documentation, not source code.

## Verdict

STATUS: PLAUSIBLE / NOT SOURCE-AUDITABLE

Mirage documents a similar architecture but does not provide implementation source. It is useful as independent commercial/community evidence that the architecture is being shipped, but it cannot verify protocol mechanics.

## Claims Observed

STATUS: VENDOR/OPEN_SOURCE_DOC CLAIM

Mirage claims:

- GPS override uses Apple's developer location service.
- iOS 18-26 needs a one-time RPPairing file from a computer.
- iOS 27 can pair on-device using Developer Mode "Pair with Host".
- Free sideload uses external LocalDevVPN.
- Paid signing unlocks built-in VPN.
- Wi-Fi/network-positioning mode is a separate engine using VPN plus trusted certificate.
- Mobile data operation is supported.

## Cellular Claim

STATUS: PLAUSIBLE BUT UNCONFIRMED

Mirage setup docs say LocalDevVPN plus cellular can produce refused connections while cellular is the only IPv4 route, and its workaround is:

```text
tap Teleport
turn Mobile Data off for a few seconds
session starts
turn Mobile Data back on
session keeps running
```

This is a valuable hypothesis for IOSSim experiments, not proof. It implies the blocking layer may be route/path policy rather than DVT authentication.

## Relationship To Locus

STATUS: CONFIRMED DOC CLAIM

Locus README explicitly says it is not affiliated with Mirage/Wapixel. Mirage appears to predate Locus as a closed-source/productized implementation, while Locus provides source-auditable evidence for the same mechanism.

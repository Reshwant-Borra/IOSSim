# Open Questions

1. Can a new raw RPPairing tunnel to `10.7.0.1:49152` be created when Wi-Fi is off and cellular is on from cold launch?

2. If cellular cold-start fails, is the failure TCP refusal, packetFlow routing, listener absence, RPPairing authentication, or DVT service refusal?

3. Does temporarily disabling Mobile Data while LocalDevVPN is active make the developer listener reachable, as Mirage claims?

4. Can the same local virtual route bootstrap with Wi-Fi off and cellular off?

5. Does the RemotePairing listener bind to the LocalDevVPN `utun` interface or only to a Wi-Fi-associated interface?

6. What exact iOS versions expose port `49152` for raw RPPairing on the same-device path?

7. Do imported RPPairing records survive iPhone reboot, iOS minor update, iOS major update, Developer Mode toggle, and app reinstall?

8. What signing profile can ship a built-in Packet Tunnel extension for IOSSim: Personal Team, paid developer account, TestFlight, or App Store?

9. Can the first POC avoid a built-in Packet Tunnel by requiring external LocalDevVPN and still be acceptable for architecture validation?

10. What is the sustainable DVT coordinate update rate for Drive: 0.5 Hz, 1 Hz, 2 Hz, or 5 Hz?

11. Does `LocationSimulation` clear automatically when the DVT connection drops, or can stale simulated state remain until explicit clear/reboot?

12. Does iOS 27 same-device PairableHost remain reliable outside the current beta/version evidence?

13. Can IOSSim use idevice FFI as-is on iOS arm64 with acceptable binary size and startup latency?

14. Which diagnostics can be exposed without leaking pairing/private-key material?

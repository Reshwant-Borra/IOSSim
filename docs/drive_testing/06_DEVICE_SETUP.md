# Device Setup

1. Connect an owned or authorized iPhone by USB.
2. Unlock it and accept **Trust This Computer** if prompted.
3. Enable Developer Mode.
4. Start IOSSim in `drive-testing` mode.
5. Open Device Check and click **Initialize Device**.
6. Mount the Developer Disk Image.
7. Start the tunnel when iOS 17 or newer requires it.
8. Run the readiness check.

Trust and DDI mounted state are not currently exposed by DeviceManager status. The UI reports those checks as unavailable/warnings rather than inventing values.

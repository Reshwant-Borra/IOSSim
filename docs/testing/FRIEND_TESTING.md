# Veya — Friend Testing Guide (private test build)

Build: `Veya-Test-8155901.dmg`. This is a **private test build**, not a public release. It is not
notarized, so macOS will ask you to approve it. Budget 20–40 minutes, and have your iPhone, its USB
cable and your Apple Account password ready.

Before you start, check the file you received. The sender will give you its SHA-256 separately:

```
shasum -a 256 ~/Downloads/Veya-Test-8155901.dmg
```

It must print `9dde51d5dbc806a079875e9a54edcaede0c18a0c53bcaa2a177aa4b5728bc54f`. If it doesn't,
stop and tell the sender.

## 1. What you need

**Mac**

- macOS 13 or later (Apple silicon or Intel).
- Internet access. Veya talks to Apple and downloads an Apple developer disk image for your iOS
  version.
- You do **not** need Xcode. Please don't install it for this test.

**iPhone**

- iOS 17 or later, with a passcode, unlocked during setup.
- A USB cable that carries data (not a charge-only cable).
- The free **LocalDevVPN** app from the App Store (Veya will tell you when to install it; you can also
  install it in advance).
- Your own Apple Account. A free account works; Veya uses its free "Personal Team".

## 2. Install Veya on the Mac

1. Double-click `Veya-Test-8155901.dmg`. A window named **Veya Test** opens.
2. Drag **Veya Development** onto **Applications**.
3. Eject **Veya Test** (click the eject icon in Finder). Don't run Veya from the disk image.
4. Open **Applications** and double-click **Veya Development**.
5. If macOS says it can't verify the app: open **System Settings → Privacy & Security**, scroll down,
   click **Open Anyway** next to Veya Development, and confirm with your Mac password. Don't disable
   Gatekeeper or run terminal commands to get around this.

The window shows "M4 DEFERRED – PRE-RELEASE BLOCKER" in red. That's expected for this test build.

## 3. Connect the iPhone by USB

1. Plug the iPhone into the Mac **with the cable**. The first trust step needs USB, even if the phone
   is also on the same Wi-Fi.
2. Unlock the iPhone.
3. In Veya, click the **↻ (Refresh devices)** button and pick your iPhone in the **iPhone** menu.

## 4. Trust / Pair

1. Click **Trust / Pair**.
2. On the iPhone, tap **Trust** on "Trust This Computer?" and enter your iPhone passcode.
3. Veya shows "Lockdown session validated."

## 5. Developer Mode (only if Veya asks)

If your iPhone already has Developer Mode on, Veya skips this and shows **Install / Prepare**.

1. Veya shows **Enable Developer Mode**. Click it. This only makes the Developer Mode switch
   **visible** on the iPhone. It doesn't turn anything on.
2. On the iPhone: **Settings → Privacy & Security → Developer Mode** → turn it **on**.
3. **The iPhone will ask to restart. Let it.** After the restart, unlock it and confirm **Turn On** when
   asked, then enter your passcode.
4. Keep the cable connected, unlock the iPhone, and click **Continue** in Veya.
   Veya checks the iPhone itself; clicking Continue alone never counts as proof. If it says "Checking
   Developer Mode", make sure the phone is unlocked and click **Continue** again.

## 6. Sign in with your Apple Account

1. Enter your Apple Account email and password and click **Sign In**.
2. If asked, enter the verification code sent to your devices and click **Verify**.
3. Veya shows "Authorized: …" with your name or team.

Your password is only used to sign in and isn't saved. This test build forgets the sign-in when
Veya quits, so you'll sign in again after a relaunch.

## 7. Install / Prepare

Click **Install / Prepare**. Veya creates a signing certificate and profile for your account,
registers your iPhone with your free Personal Team, signs the Veya iPhone app, and installs it. This
can take a minute or two. The **Current device state** list updates as each part completes.

If Apple says your account has too many development certificates, Veya shows what to do. Follow
it, then click the button again.

## 8. Trust the developer on the iPhone

The first time, iOS won't open an app from a new developer until you allow it. Veya detects this and
shows **Trust Developer**:

1. On the iPhone: **Settings → General → VPN & Device Management**.
2. Under **Developer App**, tap the **Apple Development** entry with your Apple Account.
3. Tap **Trust "Apple Development: …"**, then **Trust** again.
4. Return to Veya and click **Continue**.

Veya never does this step for you. It is your permission to give.

## 9. LocalDevVPN

If Veya shows **Connect LocalDevVPN**, do what the orange message says. It will be one of:

- "Install LocalDevVPN on your iPhone…" → install **LocalDevVPN** from the App Store, then **Continue**.
- "Open LocalDevVPN, allow the VPN configuration…" → open LocalDevVPN, tap **Allow** on the VPN
  prompt (enter your passcode if asked), then **Continue**.
- "Open LocalDevVPN and tap Connect…" → open it, tap **Connect**, return to Veya, **Continue**.

Keep LocalDevVPN connected for the rest of setup.

## 10. Run Setup

When Veya shows **READY FOR SETUP**:

1. On the iPhone, open the **Veya** app (named *IOSSim DVT POC* on the home screen) and tap **Run Setup**.
2. If the iPhone asks to allow automation or access for Veya, allow it.
3. Return to the Mac and click **Continue / Verify Setup**.

## 11. Done

Success looks like:

- Title **READY**, with the text "Setup is complete and the iPhone is ready."
- In **Current device state**, every row reads **satisfied**: application, artifact, authorization,
  certificate, developerSupport, migration, pairing, payload, profile, runtime, signingKey, team, vpn.

Please send a screenshot of this screen.

## If something goes wrong

Stop at the **first** failure and don't install extra tools (Xcode etc.). Send:

1. A screenshot of the whole Veya window, including the **Last action failed** box (domain, the
   `VEYA-…` code, and the message) and the **Current device state** list.
2. A photo or screenshot of what the iPhone showed at that moment.
3. Which step number above you were on, and what you clicked last.
4. Your macOS version, Mac type (Apple silicon / Intel), iPhone model and iOS version.
5. If the sender asks for them, these two files (they contain no passwords or keys):
   - `~/Library/Application Support/Veya/development-session/localdevvpn-transition-trace.jsonl`
   - `~/Library/Application Support/Veya/development-session/apple-diagnostics.json`

**Never send**: your Apple Account password or verification codes; anything from
`~/Library/Application Support/Veya/development-session/secrets/`, `certificates/`, `profiles/`
or `staging/`; `.mobileprovision` or `.cer` files; Keychain exports; or screenshots of your Apple
Account security settings.

Known limitation: if you sign in with a **different** Apple Account after already completing setup
with another one, Veya currently stops with `VEYA-TEAM-032` ("The signed-in Apple Account is not
the one Veya's certificate belongs to."). This is a known open issue. Please report it if you hit it,
but don't try to work around it.

## Removing the test build

Delete **Veya Development** from Applications and the folder
`~/Library/Application Support/Veya/development-session`. On the iPhone, delete the Veya
(*IOSSim DVT POC*) app. Optionally remove the developer under **VPN & Device Management**, turn off
Developer Mode, and remove LocalDevVPN.

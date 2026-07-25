# Store Listings — Piper (Google Play)

Reference copy for the store listing. Keep in sync when metadata changes.

> **The App Store half of this document does not apply to this fork.** Apple
> platforms are out of scope (see [FORK.md](../FORK.md#plataformas-apple-fora-de-escopo)):
> there is no Apple Developer membership, no signing identity and no iOS
> pipeline. The iOS sections below are kept as inherited reference — screenshot
> specs, review notes, the demo-video checklist — because they cost nothing to
> keep and would be expensive to reconstruct if that decision is ever revisited.
> **Nothing in them describes a shipping path today.**

- **Android applicationId:** `ch.pungitore.piper` (separate Play namespace — no conflict)
- **Min Android:** API 34 (Android 14)
- ~~**iOS Bundle ID**, **Apple Team**, **Min iOS**, **iPhone + iPad**~~ — not applicable, see above

> ⚠️ **Copy rule:** never claim "end-to-end encrypted". The relay still sees
> plaintext traffic. The honest privacy story is **TLS + a self-hostable relay
> you control**. Keep this line in all marketing copy.

---

## Names

**App Name** (24/30)
```
Remote Pi: Coding Agents
```

> The on-device name (`CFBundleDisplayName`) stays "Remote Pi" — independent of
> the store name, which must be globally unique. "Remote Pi" exact is taken by a
> live app (Ten Fifty Ventures LLC, `com.luisartola.RemotePi`).

**Subtitle** (≤30) — pick one:
```
A mesh of coding agents          (23)
Your phone holds the keys        (25)
Pair, watch, and approve         (24)
```

## Promotional Text (≤170, editable anytime without review)
```
Pair your phone to every machine you code on. Watch your AI agents work, approve their tool calls, and keep them moving — all from your pocket. Open source.
```

## Keywords (92/100, no spaces; words already in the name/subtitle are omitted)
```
ssh,terminal,developer,cli,ai,assistant,claude,devtools,server,pairing,self-hosted,devops,qr
```

## Description (≤4000)
```
Remote Pi turns your iPhone into the control surface for the AI coding agents running on every machine you work from.

Pair your phone once by scanning a QR code on your Mac. From then on your devices form a mesh: the agents on your machines talk to each other, and your phone is the trusted key that authorizes new peers and lets you step in from anywhere.

WHAT YOU CAN DO
• Scan a QR code to pair with a machine in seconds
• See every active agent session across all your paired machines in one list
• Follow the conversation live as your agent streams its work
• Approve or reject tool calls with a tap — you stay in control of what runs
• Move between machines without losing context

YOUR PHONE IS JUST THE AUTHENTICATOR
You don't run the heavy work on your phone. The agents live on your computers; your phone holds the cryptographic identity that vouches for new devices and gives you a window into what's happening. Pairing uses Ed25519 device keys over TLS.

WORKS WITH THE HARNESS YOU USE
Remote Pi rides alongside the coding-agent setup you already run on your machines instead of replacing it.

OPEN SOURCE & SELF-HOSTABLE
Remote Pi is open source. Start with the public relay, or point the app at your own self-hosted relay so the connection between your devices runs on infrastructure you control.

Built for developers who want their agents within reach — on the couch, on the move, or away from the desk.
```

## What's New (1.0.1)
```
First public release of Remote Pi. Pair your phone with your machines, watch your coding agents work in real time, and approve their tool calls from anywhere. Feedback is very welcome.
```

## URLs
```
Support URL:        https://remote-pi.jacobmoura.work
Marketing URL:      https://remote-pi.jacobmoura.work
Privacy Policy URL: https://remote-pi.jacobmoura.work/privacy
```

## Classification
- **Primary category:** Developer Tools
- **Secondary category:** Productivity
- **Age rating:** 4+ (no sensitive content)

## App Privacy
Declare **Data Not Collected**.

Rationale: no analytics/crash SDK; ML Kit (QR scan via `mobile_scanner`) is
on-device; `flutter_secure_storage` / `hive` are local-only; the relay only
routes ephemeral traffic.

> Confirm the public relay does not persist/log personal data. If it does, that
> data type must be declared instead.

---

## Screenshots

- **Device:** iPhone 17 Pro Max — 6.9", native **1320 × 2868 px**. Submission-ready;
  App Store Connect auto-scales the 6.9" set to smaller iPhone sizes.
- **Capture clean:** mirror the iPhone via QuickTime (New Movie Recording → pick
  the iPhone) or the Xcode Devices window; or shoot on-device and AirDrop the PNGs.
- Apple no longer requires a clean status bar, but aim for full battery/signal,
  tidy time. The `xcrun simctl status_bar` override is simulator-only.
- Verify exported PNGs are exactly **1320 × 2868** before upload.

**Shot list (5):**

| # | Screen | Caption |
|---|---|---|
| 1 | QR scan pairing with the Mac | **Pair in seconds** |
| 2 | Sessions / peer list (the mesh) | **Every machine, one view** |
| 3 | Chat with live agent streaming | **Watch your agents work, live** |
| 4 | Tool-call approval card | **You approve what runs** |
| 5 | Settings / relay choice | **Your relay, your rules** |

---

## App Review Information

> **Why this matters:** Remote Pi is a *companion* app — it can't show full
> functionality without a paired machine, and each pairing code is **single-use
> and expires in 60 s** (see `lib/pairing/qr_scanner.dart`). A static code in the
> notes would be dead by the time a reviewer tries it. The accepted solution for
> this class of app is a **demo video**. Build the review story around it.

**Sign-in required:** No (the app has no user account / no login).

**Demo account:** N/A — testing is via the pairing flow, not an account.

**Contact information** (required fields):
```
First / Last name:  Jacob / Moura
Phone:              <your phone, intl format e.g. +55 ...>
Email:              alessandro@pungitore.ch
```

**Attachment:** the demo video (mp4) and/or a link to it in the notes below.

### Reviewer Notes (paste into App Review Information → Notes)
```
ABOUT THE APP
Remote Pi is a companion app for developers. It does not work standalone: it pairs with a coding-agent "harness" running on your own computer (Mac/Linux) and lets you monitor those agents and approve their actions from your phone. There is no user account and no sign-in.

WHY A DEMO VIDEO IS PROVIDED
Pairing requires a live companion machine, and each pairing code is single-use and expires after 60 seconds (a security measure). A static code in these notes would expire before review. The video here — [PUBLIC VIDEO LINK] — shows the complete flow end to end on a physical iPhone: pairing, the live session list across machines, streaming agent output, and approving a tool call.

WHAT YOU CAN VERIFY WITHOUT A COMPANION
On a fresh install you can complete onboarding, choose the public relay, and reach the pairing screen. The camera permission is used only to scan the pairing QR shown by the companion machine. A "Can't scan? Paste code instead" option accepts the code as text, so no camera or second device is required to exercise the pairing UI.

LIVE DEMO ON REQUEST
If you would like to exercise pairing live, contact us via Resolution Center and we will bring a sandboxed demo machine online and provide a fresh pairing code in real time.

NETWORK & PRIVACY
The app connects to a relay over TLS to reach your machines. Public relays must use TLS; cleartext (http/ws) is permitted only on the local network for self-hosted relays. No personal data is collected.

CONTACT
ngSoftware — alessandro@pungitore.ch
```

### Demo video — recording checklist
Record on the same iPhone 17 Pro Max used for screenshots. Have a Mac running
the relay + harness + a coding agent on a **sandboxed / innocuous project**.

1. Launch app → onboarding → relay = **community** (default)
2. Pair step → scan the QR shown on the Mac (or show "Can't scan? Paste code instead")
3. Sessions / peer list with **1–2 active sessions** visible (the mesh)
4. Open a chat → show the agent **streaming** output live
5. Trigger a **tool call** → show the approval card → **Approve**
6. Keep it ~30–60 s, real functionality, no placeholder/empty states

Host it unlisted (YouTube/Vimeo) or on the site, and put the link in the notes
above. (A direct .mp4 can also be uploaded to the attachment field.)

---
---

# Google Play (Android)

Reuses the same brand voice and the **no-E2E copy rule** above.

- **applicationId:** `ch.pungitore.piper` (Play namespace is independent of
  Apple — the iOS rename does NOT apply here; this ID is fine on Play)
- **Min SDK:** API 34 (Android 14) — intentional, `remote_pi_identity` needs
  Block Store. **Target SDK:** Flutter default (verify it meets Play's current
  minimum target — API 35 for new apps).
- **Signing:** already configured. Upload key in `android/signing/remotepi-release.jks`
  (alias `remotepi`), loaded via `android/key.properties`. On first upload, enroll
  in **Play App Signing** (Google manages the app key; this keystore is the upload key).
  - Upload key **SHA-1:** `C6:F8:AF:C9:4B:31:98:D7:5B:75:08:78:4E:F3:8C:AD:70:1A:06:89`
  - Upload key **SHA-256:** `92:5C:FB:3B:90:76:E0:81:19:E0:12:5B:34:77:38:44:9B:70:BF:CF:53:8F:8A:DC:A6:63:5A:68:AC:B1:9E:40`
  - ⚠️ **Back up this keystore + `key.properties` securely.** Losing the upload key
    means contacting Google to reset it; losing it before Play App Signing enrollment
    is unrecoverable.
- **Bundle:** `flutter build appbundle --release` → `build/app/outputs/bundle/release/app-release.aab`
  (Play requires `.aab`, not `.apk`). Current: versionCode 2, versionName 1.0.1.

## Listing fields

**App title** (≤30) — Play does **not** require a globally-unique name, so either works:
```
Remote Pi: Coding Agents     (matches App Store)
Remote Pi                    (plain — available on Play)
```

**Short description** (≤80)
```
Watch and approve your AI coding agents on every machine, from your phone.
```

**Full description** (≤4000) — Android-adapted ("phone"/"computer" instead of
"iPhone"/"Mac"). Bullets render fine on Play.
```
Remote Pi turns your phone into the control surface for the AI coding agents running on every machine you work from.

Pair your phone once by scanning a QR code on your computer. From then on your devices form a mesh: the agents on your machines talk to each other, and your phone is the trusted key that authorizes new peers and lets you step in from anywhere.

WHAT YOU CAN DO
• Scan a QR code to pair with a machine in seconds
• See every active agent session across all your paired machines in one list
• Follow the conversation live as your agent streams its work
• Approve or reject tool calls with a tap — you stay in control of what runs
• Move between machines without losing context

YOUR PHONE IS JUST THE AUTHENTICATOR
You don't run the heavy work on your phone. The agents live on your computers; your phone holds the cryptographic identity that vouches for new devices and gives you a window into what's happening. Pairing uses Ed25519 device keys over TLS.

WORKS WITH THE HARNESS YOU USE
Remote Pi rides alongside the coding-agent setup you already run on your machines instead of replacing it.

OPEN SOURCE & SELF-HOSTABLE
Remote Pi is open source. Start with the public relay, or point the app at your own self-hosted relay so the connection between your devices runs on infrastructure you control.

Built for developers who want their agents within reach — on the couch, on the move, or away from the desk.
```

**Privacy Policy URL** (required): `https://remote-pi.jacobmoura.work/privacy`

**Category:** Tools (primary). **Tags:** developer tools, productivity.
**Contains ads:** No. **In-app purchases:** No.

## Graphics (Play-specific assets you must produce)
- **App icon:** 512 × 512 PNG (32-bit; alpha allowed on Play, unlike Apple's store icon)
- **Feature graphic:** 1024 × 500 PNG/JPEG — **required**, shown atop the listing
- **Phone screenshots:** 2–8. Each side 320–3840 px.
  - ⚠️ The iPhone shots are **1320×2868 = 2.17:1**, which exceeds Play's preferred
    **2:1** max ratio — they may be rejected or letterboxed. Safest: capture on an
    **Android emulator/device** (use the "Paste code" pairing fallback for live
    content), or pad the existing shots to ≤2:1.
- **Tablet screenshots:** optional (only if you want the "Designed for tablets" badge).

## Data safety form (Play's privacy questionnaire — required)
- **Data collected / shared:** None. No analytics/crash SDK; ML Kit (QR) is on-device;
  storage is local; the relay only routes ephemeral traffic.
- Declare the **Camera** permission usage (QR scan, on-device, not collected).
- Confirm the public relay does not persist personal data (else declare it).

## Content rating
Complete the IARC questionnaire → expected **Everyone / PEGI 3** (no sensitive content).

## App access / reviewer testing
Same companion-app constraint as iOS: full functionality needs a paired machine and
pairing codes are single-use / 60 s. In **App content → App access**, add instructions
explaining the app is a companion to a desktop coding-agent harness, that no login is
required, and link the **demo video** (see the iOS recording checklist above — the same
video works). Optionally add it as the listing **Promo video** (YouTube).

## Known Android gaps / v1.1 follow-ups (not submission blockers)

**1. 16 KB memory page alignment.** Play warns the app isn't compatible with 16 KB
page sizes (publishable with the warning for now, but a growing hard requirement).
Two native libs from `mobile_scanner` (5.2.3) are 4 KB-aligned, not 16 KB:
- `libbarhopper_v3.so` (GoogleMLKit barcode)
- `libimage_processing_util_jni.so` (CameraX)

The Flutter/Dart libs (`libapp.so`, `libflutter.so`, `libdartjni.so`) are already
16 KB-aligned. Fix for v1.1: upgrade `mobile_scanner` to 7.x (pulls 16 KB-aligned
MLKit + CameraX; needs Dart scanner-API migration + test), or override the MLKit/
CameraX dependency versions in `android/app/build.gradle.kts`. Shipping v1 with the
warning is low-risk: 16 KB-page devices are rare and the app has a camera-less
"Paste code" pairing fallback. Verify with:
`flutter build appbundle --release` then check `.so` LOAD-segment alignment ≥ 0x4000.

**2. Cleartext to local relays.** `AndroidManifest.xml` has no `usesCleartextTraffic`
/ network-security-config, so **http:// self-hosted local relays won't connect on
Android** (cleartext blocked by default on API 28+). iOS got the equivalent via
`NSAllowsLocalNetworking`. For parity, add a network security config permitting
cleartext to private/local addresses. Public (TLS) relays work fine without it.


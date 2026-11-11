# Submix: handoff notes

_Last updated 2026-11-11._

## What it is
A per-app audio mixer for macOS. Each app you add (Discord, Spotify, a browser) gets a channel strip with a fader, meter, Mute and Solo. Submix sums them and plays the mix to one output device, for example AirPods. Same 1-bit Mac System 4 look as AutoClicker, Lookout and Relabel (`~/Documents/dev/…`).

## Current state
- **v0.1.0** (set in `build.sh`). Public on GitHub: https://github.com/banqed/Submix (branch `main`, no tags or releases).
- Commits use the `banqed` account with the GitHub no-reply email, set in this repo's local git config.
- **Verified by Claude:**
  - Engine harness: a test tone played by `afplay` was tapped, muted from its normal route, and came out of the mix at the right level (peak matched the file) and the right pitch, with the output device at 24 kHz and the tap at 48 kHz.
  - In the app: a channel for Terminal picked up the same tone, the meters moved, and the tap was rebuilt when the `afplay` process exited.
  - Window checked by screenshot with four strips.
- **Not yet verified:** real Discord + Spotify mixing by ear, the Add App menu and fader dragging (never clicked), the permission prompt when launched with `open`, unplugging the output mid-mix.

## Running it
```
./build.sh
open Submix.app
```
Same build approach as the other three (`swiftc` over `Sources/*.swift`, hand-written `Info.plist`, bundled ChicagoFLF, "Tyler Local Code Signing" identity with ad-hoc fallback). Needs macOS 14.2 or later for process taps.

Submix needs **System Audio Recording** permission (System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only). The prompt appears the first time an app is added. `Info.plist` carries `NSAudioCaptureUsageDescription`.

`SUBMIX_DEBUG=1 ./Submix.app/Contents/MacOS/Submix` logs taps and stream formats to stderr and suppresses the permission prompt.

Settings are in `UserDefaults` (`com.banqed.submix`): `channels` (JSON), `masterDb`, `outputUID`, `outputName`.

## Code layout (`Sources/`)
| File | What lives there |
|---|---|
| `ClassicUI.swift` | Shared UI kit, copied unchanged from Relabel |
| `Audio.swift` | Core Audio helpers (`CA`), `AppLookup` (audio process → owning app), `CapturePermission`, `MixEngine` |
| `Model.swift` | `Taper` (fader law), `Channel`, `Mixer` (settings, sync loop, meters) |
| `Views.swift` | Strips, fader, meter, scale, Add App menu, `DitheredIcon` |
| `App.swift` | Window setup; `applicationWillTerminate` tears the engine down |

## How it works
- **Taps:** one `CATapDescription(stereoMixdownOfProcesses:)` per channel, private, with `muteBehavior = .mutedWhenTapped`. The app is silenced on its normal output only while Submix is reading it, so quitting, Bypass, or a missing output device hands every app straight back to normal playback.
- **One aggregate device:** the output device (main sub-device, clock source) plus every tap (drift-compensated) go into a private aggregate device. A single IO block reads all taps and writes the mix, so there is no ring buffer and no extra latency beyond the device's own. Core Audio resamples the taps to the output's rate.
- **Render callback** (`MixEngine.render`): only raw pointers, no locks or allocation. Per-slot state is four floats (target gain, current gain, peak L, peak R) in one shared buffer; the UI writes target gains and reads-and-clears peaks. Gains ramp across each buffer. The master stage hard-limits to ±1.
- **Tap buffers are the last N input buffers** of the aggregate, after any input streams the output device itself has.
- **Helper processes:** Discord, Chrome and others play from helper processes. `AppLookup.owner` maps each Core Audio process to an app using the process itself if it's a regular app, then `responsibility_get_pid_responsible_for_pid` (private, looked up with `dlsym`), then the parent chain. A channel taps every process that maps to its bundle ID.
- **Sync:** `Mixer.sync()` runs on Core Audio listeners (process list, device list, default output) and a 2-second timer. It recomputes what should be tapped and calls `MixEngine.apply`, which returns early when nothing changed. Any change rebuilds the aggregate (a few ms of dropout).
- **Permission:** `CapturePermission` calls `TCCAccessPreflight` / `TCCAccessRequest` in the private TCC framework for `kTCCServiceAudioCapture`, because there's no public way to ask. If the symbols disappear it reports "granted" and the app still works. The engine only runs when the status is granted, so an unanswered prompt can never leave an app muted.
- **Fader law:** linear in dB from −48 to +6, bottom 3% of travel is off, half-dB steps, snaps to 0. Double-click resets to 0 dB. Meters use the same scale and are post-fader; anything above the 0 mark is over full scale.
- **Icons:** each app icon is reduced to 32×32, contrast-stretched, outlined and Atkinson-dithered (`IconCache.dither`).

## Gotchas
- **AirPods at 24 kHz:** if the AirPods are also the system *input*, macOS puts them in call mode and everything sounds like a phone call. That is macOS, not Submix. Pick another mic (the Shure MV7) as input to get full quality.
- A process launched from a terminal counts as that terminal app (that's how the test tone was routed).
- When an app's set of audio processes changes (a new browser tab starts playing), its tap is recreated and the aggregate rebuilt, which can click.
- If the output device also has inputs (a USB interface), the aggregate opens them too, so the mic indicator may light. The audio isn't used.
- Closing the window quits, like the other apps, which also stops the mixing.
- Running the binary directly from a terminal makes TCC judge the terminal, not Submix. Use `open Submix.app` to test the real permission flow.

## Ideas not done
- Hardware inputs as channels (a mic or line-in strip)
- A second output (monitor mix / record feed), or per-channel output routing
- Update the aggregate's tap list in place instead of rebuilding
- Pan, a soft limiter on the master, saved scenes
- Menu bar mode so it can run without the window

# Submix

A per-app audio mixer for macOS with a 1-bit classic-Mac look.
Same style as [AutoClicker](https://github.com/banqed/AutoClicker) and [Lookout](https://github.com/banqed/Lookout).

## How it works

Choose **Add App** to give an app its own channel strip, then set its level with the fader.
Submix takes over the sound of every app you add, sums them, and plays the mix to the device
picked under **Output** (for example Bluetooth headphones). Apps you haven't added play as normal.

- **Fader**: −48 to +6 dB, off at the bottom. Double-click for 0 dB.
- **Mute** and **Solo** per app, plus a **Master** fader and mute.
- **Meters** show each app after its fader, and the final mix.
- **Bypass** hands every app back to its normal output without quitting.
- Channels are remembered. An app that isn't running or isn't making sound shows as *silent*
  and is picked up again when it starts.

Quitting Submix puts everything back the way it was.

## Permission

macOS asks for **System Audio Recording** the first time you add an app. Submix only reads the
apps you add, and nothing is recorded or saved.

## Build

Requires the Xcode command line tools and macOS 14.2 or later.

```sh
./build.sh
open Submix.app
```

## Font

The UI uses [ChicagoFLF](https://fontlibrary.org/font/chicagoflf) by Robin Casady,
which is in the public domain. See `Fonts/README.ChicagoFLF`.

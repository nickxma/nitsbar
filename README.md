# Brightness HUD

A tiny native macOS menu-bar brightness controller for Apple displays.

The menu bar shows the exact macOS brightness step as a fraction such as `27/32`. Each brightness-key press moves exactly one step and updates the fraction immediately from the same action that writes the real macOS display brightness. There is no luminance estimate or delayed nits calculation in the interaction path.

Click the fraction to control brightness with a slider, toggle Launch at Login, or quit the app.

## Why 32 steps?

macOS's traditional brightness keys divide the slider into 16 increments. Brightness HUD uses half-size increments, so the range has 32 increments and 33 positions: `0/32` through `32/32`. One keypress is exactly 1/32, or 3.125%.

`0/32` means the display's lowest software brightness setting, not zero emitted light. `32/32` means the maximum macOS brightness-slider setting. BrightIntosh or another EDR tool can still apply its own scaling on top.

## Keyboard control

The running app accepts these direct step requests through its own executable:

```sh
'/Users/nick/Applications/NitsBar.app/Contents/MacOS/NitsBar' --request-step -1
'/Users/nick/Applications/NitsBar.app/Contents/MacOS/NitsBar' --request-step 1
```

Keyboard Maestro, Karabiner-Elements, or another remapper can invoke those actions for F1 and F2. The short-lived command sends the request to the already-running menu-bar app. Its persistent control port serializes rapid keypresses, changes every active software-controllable Apple display, and returns only after the exact target fraction has been applied to the HUD.

## Build

Requires macOS 13 or later and Xcode or the Xcode command-line tools:

```sh
zsh build.sh
open build/NitsBar.app
```

The app is a single Swift source file with no third-party dependencies.

## Compatibility and privacy

Brightness HUD dynamically uses Apple's private `DisplayServices` framework so it can read and write the same normalized brightness value used by macOS. It has been tested with Studio Display XDR and a built-in Liquid Retina XDR display on macOS 26.6. Because this is a private API, a future macOS update could require an adjustment.

No administrator access, log access, network connection, telemetry, or privileged or persistent helper process is used. The app is not affiliated with Apple.

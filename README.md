# WindowInvert

A small macOS menu bar app that color-inverts **one window** — handy for reading old, scanned PDFs in "dark mode" when Preview's own Dark Appearance does nothing.

| Shortcut | Action |
|---|---|
| **⌥8** (Option-8) | Invert the whole front window (toggle) |
| **⌥9** (Option-9) | Invert only the window's content, leaving the title bar / toolbar / sidebar alone (toggle) |

Press the same shortcut again to turn it off. Pressing the other shortcut switches modes. You can invert several windows at once; **Stop All Inversions** is in the menu.

The menu bar icon also has: Classic vs. Hue-Preserving invert (hue-preserving keeps reds red and blues blue while flipping brightness), permission status, and Launch at Login.

## How it works

macOS has no public API to recolor another app's window, so WindowInvert:

1. Captures just the target window with **ScreenCaptureKit** (~60 fps).
2. Inverts each frame on the GPU (**Metal**).
3. Draws it in a borderless overlay window sitting directly above the target. The overlay **ignores all mouse events**, so clicks, scrolling, text selection and keyboard input go straight to the real app.
4. Follows the window every display refresh, so moving and resizing track in real time. Other windows that come in front still cover it normally.

For ⌥9, the content area is found through the Accessibility API (Preview's PDF view, a browser's web area, a text view, etc.). If nothing suitable is found, it falls back to skipping the title bar.

## Install

### Prebuilt

1. Unzip `WindowInvert.zip` (universal: Apple Silicon + Intel) and move `WindowInvert.app` to `/Applications`.
2. It is not notarized, so the first time: right-click → **Open** (or System Settings → Privacy & Security → **Open Anyway**).

### Build from source

Requires macOS 14+ and Xcode 15+ (or the Command Line Tools with Swift 5.9+).

```sh
git clone https://github.com/pazimzadeh/WindowInvert.git
cd WindowInvert
./scripts/create-signing-cert.sh   # optional, once: stable signature so permissions survive rebuilds
./build.sh                         # universal (arm64 + x86_64); ARCHS=native ./build.sh for faster builds
cp -R build/WindowInvert.app /Applications/
open /Applications/WindowInvert.app
```

## Permissions

On first use macOS asks for two permissions (System Settings → Privacy & Security):

- **Screen & System Audio Recording** — to capture the window being inverted. After granting it, quit and reopen WindowInvert (macOS requirement).
- **Accessibility** — to find the front window and, for ⌥9, its content area.

The menu shows whether each permission is granted. If you rebuild with an ad-hoc signature, macOS may treat it as a new app; remove the old WindowInvert entries and grant again, or use `create-signing-cert.sh`.

## Limitations

- While WindowInvert is running, ⌥8 / ⌥9 no longer type `•` / `ª`.
- The overlay is a live copy, so it's about one frame behind the real window; during fast resizes or scrolls you may notice a slight lag at the edges.
- macOS shows the purple screen-recording indicator in the menu bar while a window is inverted.
- The overlay hides when the target window is minimized or otherwise off screen, and comes back when it returns.
- Only tested so far with Preview on macOS 26. Other apps should work for ⌥8; ⌥9 depends on how well the app reports its content area to Accessibility.

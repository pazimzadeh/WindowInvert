# WindowInvert

A small macOS menu bar app that color-inverts **one window** — handy for reading old, scanned PDFs in "dark mode" when Preview's own Dark Appearance does nothing.

| Shortcut | Action |
|---|---|
| **⌥8** (Option-8) | Invert the whole front window (toggle) |
| **⌥9** (Option-9) | Invert only the window's content, leaving the title bar / toolbar / sidebar alone (toggle) |
| **⌥0** (Option-0) | Switch invert style: Classic ↔ Hue-Preserving |
| **⌥7** (Option-7) | Stop all inversions |

All three shortcuts can be changed (or cleared) in **Settings…** from the menu bar icon.

Press the same shortcut again to turn it off. Pressing the other shortcut switches modes. You can invert several windows at once; **Stop All Inversions** (⌥7) turns them all off.

The menu bar icon also has: Classic vs. Hue-Preserving invert (hue-preserving keeps reds red and blues blue while flipping brightness), a contrast setting (High / Medium / Soft — Medium and Soft lift the black background to dark grey while text stays white), permission status, and Launch at Login.

## How it works

macOS has no public API to recolor another app's window, so WindowInvert:

1. Captures just the target window with **ScreenCaptureKit** (~60 fps).
2. Inverts each frame on the GPU (**Metal**).
3. Draws it in a borderless overlay window sitting directly above the target. The overlay **ignores all mouse events**, so clicks, scrolling, text selection and keyboard input go straight to the real app.
4. Follows the window every display refresh, so moving and resizing track in real time. Other windows that come in front still cover it normally.
5. Turns itself off while the app shows a sheet or popover over the window (Print, Save, Export, …). macOS already dims the window behind a sheet, and inverting that dimming would brighten it. Inversion comes back when the sheet closes. Turn on **Invert Behind Sheets & Popovers** in the menu to keep inverting; sheets then show through un-inverted.
6. In Preview, leaves the dark background around the pages dark (only the pages are inverted), so full-screen reading stays dark.
7. Keeps each overlay on its target window's Spaces and lets macOS slide both together, rather than copying the Space-transition motion into the overlay a second time.

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

- While WindowInvert is running, its shortcuts (default ⌥8 / ⌥9 / ⌥0 / ⌥7) no longer type `•` / `ª` / `º` / `¶`. Change or clear them in Settings if you need those characters.
- By default the overlay is explicitly hidden when Mission Control starts, rather than fading in place. Turn on **Invert During Mission Control** to have it follow the window's thumbnail. The overview uses the last clean captured image because ScreenCaptureKit can deliver clipped/scaled frames during Mission Control; live capture resumes on exit. The Mission Control changes still need confirmation on macOS 27.
- The overlay is a live copy, so it's about one frame behind the real window; during fast resizes or scrolls you may notice a slight lag at the edges.
- Space tracking uses dynamically loaded, private WindowServer functions to read pre-animation geometry and match the overlay's Space membership. Mission Control separately uses Dock's overview surface to detect entry/exit and a WindowServer transform to follow the thumbnail; ordinary Space slides still use only native geometry. These macOS internals may change in future releases. If native Space APIs are unavailable, public geometry/visibility queries provide reduced Space-transition fidelity; if the thumbnail transform is unavailable, the overlay hides during Mission Control instead.
- macOS shows the purple screen-recording indicator in the menu bar while a window is inverted.
- The overlay hides when the target window is minimized or otherwise off screen, and comes back when it returns.
- Tested with Preview on macOS 26 and (by the author) macOS 27. Other apps should work for ⌥8; ⌥9 depends on how well the app reports its content area to Accessibility.

## App icon

The app and menu bar icons are drawn in code (`Sources/WindowInvert/IconArt.swift`). After changing the artwork, run `./scripts/make-icon.sh` to regenerate `Resources/AppIcon.icns`.

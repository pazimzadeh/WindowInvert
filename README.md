# WindowInvert

A small macOS menu bar app that color-inverts **one window** — handy for reading old, scanned PDFs in "dark mode" when Preview's own Dark Appearance does nothing.

| Shortcut | Action |
|---|---|
| **⌥8** (Option-8) | Invert the whole front window (toggle) |
| **⌥9** (Option-9) | Invert only the window's content, leaving the title bar / toolbar / sidebar alone (toggle) |
| **⌥⌘0** (Option-Command-0) | Switch invert style: Classic ↔ Hue-Preserving |
| **⇧⌥0** (Shift-Option-0) | Cycle contrast: High → Medium → Soft → High |
| **⌥0** (Option-0) | Stop all inversions |

All five shortcuts can be changed (or cleared) in **Settings…** from the menu bar icon. Previously saved shortcuts are preserved; use each row's **Default** button to adopt a new default.

Press ⌥8 or ⌥9 again to turn that inversion off. Pressing the other inversion shortcut switches modes. You can invert several windows at once; **Stop All Inversions** (⌥0) turns them all off.

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

- While WindowInvert is running, registered shortcuts consume their key combinations (for example, ⌥8 / ⌥9 / ⌥0 no longer type `•` / `ª` / `º`). Change or clear them in Settings if you need those characters.
- **Invert During Mission Control** is on by default, so the overlay follows the window's thumbnail. Turn it off to hide the overlay during the overview. Previously saved choices are preserved. The overview uses the last clean captured image because ScreenCaptureKit can deliver clipped/scaled frames during Mission Control; live capture resumes on exit. Slow macOS 27 gestures are detected using WindowManager's overview strip together with proportional window shrink, and tracking stays active through cancellation/exit.
- The overlay is raised on app activation and focused-window changes, bridging the delay before macOS updates its window-order list. This addresses the brief original-color flash when returning to an inverted window. The temporary ordering hold ends once the window reaches the front, on another activation, or after 250 ms.
- Swiping between Spaces while Mission Control is already arranged can still show an animation mismatch between the thumbnail and overlay. This combined transition remains under investigation; ordinary Space tracking is unchanged.
- To diagnose Mission Control timing, invert a window, then choose **Record Mission Control Diagnostics (20 seconds)**. Slowly enter the overview, hold halfway for a few seconds, finish, then exit. Finder reveals the resulting JSON file after capture. It records geometry, compositor surfaces (including off-screen ones), raw transforms and tracking-callback timing on an independent sampler; it does not record images, window titles or input. It is opt-in, stops automatically, and does not change overlay behavior.
- The overlay is a live copy, so it's about one frame behind the real window; during fast resizes or scrolls you may notice a slight lag at the edges.
- Space tracking uses dynamically loaded, private WindowServer functions to read pre-animation geometry and match the overlay's Space membership. Mission Control separately detects the overview surface owned by Dock (layer 18 on macOS 26) or WindowManager (layer 19 on macOS 27), using process identity rather than localized names. A WindowServer transform follows the thumbnail; ordinary Space slides still use only native geometry. These macOS internals may change in future releases. If native Space APIs are unavailable, public geometry/visibility queries provide reduced Space-transition fidelity; if the thumbnail transform is unavailable, the overlay hides during Mission Control instead.
- macOS shows the purple screen-recording indicator in the menu bar while a window is inverted.
- The overlay hides when the target window is minimized or otherwise off screen, and comes back when it returns.
- Tested with Preview on macOS 26 and (by the author) macOS 27. Other apps should work for ⌥8; ⌥9 depends on how well the app reports its content area to Accessibility.

## App icon

The app and menu bar icons are drawn in code (`Sources/WindowInvert/IconArt.swift`). After changing the artwork, run `./scripts/make-icon.sh` to regenerate `Resources/AppIcon.icns`.

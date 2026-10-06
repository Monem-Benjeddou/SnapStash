# SnapStash

[![Build](https://github.com/Monem-Benjeddou/SnapStash/actions/workflows/build.yml/badge.svg)](https://github.com/Monem-Benjeddou/SnapStash/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/Monem-Benjeddou/SnapStash?include_prereleases)](https://github.com/Monem-Benjeddou/SnapStash/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)

A free, open-source screenshot tool for macOS. Capture an area, a window, or the whole screen, then copy, save, drag, or pin it in one step. Or copy the text out of anything on screen.

> **Early preview.** Capture, Quick Access, Pin, and Copy Text work today. Annotation, screen recording, and scrolling capture are next.

![The SnapStash window: capture buttons and recent captures](docs/screenshots/home.jpg)

<details>
<summary>First run</summary>

After setup, SnapStash shows the three things to know and a <b>Try it now</b> button.

![The first-run card](docs/screenshots/first-run.jpg)
</details>

## Features

- **A home for your captures.** The SnapStash window has one-click capture buttons with their shortcuts, and a gallery of recent captures. Hover a capture to copy it, pin it, copy its text, or show it in Finder; double-click to open it, or drag it out.
- **Easy first run.** One card walks you through the Screen Recording permission: one button, then macOS's own Quit & Reopen. Then SnapStash shows the three things to know, with a **Try it now** button. There are no pop-up alerts.

- **Area capture (⌥⇧4).**
  - The screen freezes while you select, so menus and hover states stay exactly as they were.
  - A size readout shows the selection in pixels, and a magnifier helps you hit pixel-exact edges.
  - Hold Shift for a square.
- **Window capture (⌥⇧5).**
  - Hover to highlight a window, then click to capture it.
  - The window is captured on its own, even if something covers it, with its shadow on a transparent background.
  - In area mode, a single click captures the window under the pointer, and Space switches between modes.
- **Screen capture (⌥⇧3).** Captures the whole display under the pointer.
- **Copy Text from Screen (⌥⇧2).** Select an area and its text goes straight to the clipboard. Recognition happens on your Mac with Apple's Vision framework.
- **Quick Access.** After each capture, a thumbnail appears in the corner:
  - **Copy**, **Save** or **Pin** it, or copy the text in it.
  - Drag it straight into Mail, Slack or Finder.
  - It stays put while you hover it, and several captures stack up.
- **Pin to screen.** Float a screenshot above every window.
  - Drag it to move it, and scroll or pinch to zoom.
  - Right-click to change the opacity.
  - Double-click or press Esc to close it.
- **Settings.**
  - Copy, save and Quick Access, each on or off.
  - The save folder, and PNG or JPEG.
  - Window shadow and mouse pointer, each on or off.
  - Launch at login.
  - Every shortcut can be changed.

The default shortcuts follow the system's ⇧⌘3/4/5 but use ⌥ instead of ⌘, so they don't clash with them.

## Install

**Quickest:** paste this into Terminal. It downloads the latest release, checks its checksum and signature, and installs it into Applications without the "unidentified developer" warning ([read the script first](install.sh)):

```sh
curl -fsSL https://raw.githubusercontent.com/Monem-Benjeddou/SnapStash/main/install.sh | bash
```

**Or install it yourself:**

1. Download `SnapStash-mac.zip` from the [latest release](https://github.com/Monem-Benjeddou/SnapStash/releases/latest) and unzip it.
2. Move `SnapStash.app` to `/Applications`.
3. Open it. SnapStash isn't notarized by Apple (that requires a paid developer account), so macOS blocks the first launch:
   - **macOS 15 or later:** close the warning, open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to SnapStash.
   - **macOS 14:** right-click SnapStash.app, choose **Open**, then click **Open** again.
4. SnapStash opens a short setup card. Click **Allow Screen Recording**, turn on SnapStash in System Settings, then click **Quit & Reopen** when macOS offers it.

## Privacy

Everything happens on your Mac. Captures are saved only where you choose (`~/Pictures/SnapStash` by default). Text recognition runs on-device, and nothing is uploaded anywhere.

## Reliability

When something goes wrong, SnapStash keeps your capture, says what happened in plain words, and offers a way out.

- **Crashes are caught, and SnapStash comes back.**
  - If SnapStash crashes (a runtime error, a memory error or an uncaught exception), it records what happened and reopens itself, then tells you it was reopened.
  - If it stops responding for 45 seconds, it's restarted the same way. A short freeze is only logged.
  - **Safe mode.** If it crashes twice in a row within two minutes of starting, it starts in safe mode: recent captures aren't loaded (a damaged image is the likeliest cause), and capturing still works. **Load Recent Captures** brings them back.
  - A third quick crash stops the automatic reopening, so a crash loop can't run forever.
- **Only one copy runs.** Opening a second copy (say, one in Downloads) brings the running one forward instead of starting another.
- **A capture is never lost to a folder problem.**
  - If the save folder can't be used (an ejected drive, a deleted or moved folder, no write access), the capture is saved to `~/Pictures/SnapStash` instead, and SnapStash tells you so.
  - The window shows what's wrong with **Choose Another Folder**, **Use Pictures › SnapStash**, and **Try Again**.
  - A folder on an external drive is picked up again as soon as the drive is back.
  - If neither saving nor copying works, the capture stays in Quick Access, so you can drag it out or try again.
- **Permission turned off while SnapStash is running.** Instead of a cryptic error, the setup card returns and explains how to turn it back on.
- **The screen capture service hangs.** macOS's capture service occasionally stops responding. SnapStash gives up after a few seconds and lets you try again, instead of refusing every capture until it's restarted.
- **One display fails.** With several displays, a display that can't be captured is skipped and the others still work.
- **The window closes while you pick it.** SnapStash uses what was on screen when you clicked.
- **The selection overlay never gets stuck.** It closes on its own if the displays change, the Mac goes to sleep, you switch users, or nothing happens for two minutes.
- **Restarting is safe.** **Restart SnapStash** only quits once the reopen is scheduled, and the new copy waits for the old one to exit.
- **Shortcut conflicts are shown.** If another app already uses a shortcut, the SnapStash window and Settings say so.
- **Nothing is overwritten.** Captures taken within the same second get numbered file names.
- **Logging.** Errors go to the unified log:
  ```sh
  log stream --predicate 'subsystem == "dev.snapstash.SnapStash"'
  ```

## Build from source

You need the Swift 5.10+ toolchain (Xcode or the Command Line Tools).

```sh
git clone https://github.com/Monem-Benjeddou/SnapStash.git
cd SnapStash
./build.sh            # → build/SnapStash.app (universal: arm64 + x86_64)
```

`build.sh` signs with `$SIGN_IDENTITY` if set. Otherwise it uses a local certificate named "… Local Signing" from your keychain, or falls back to ad-hoc signing. A stable certificate keeps the Screen Recording permission after a rebuild.

### Project layout

| File | Purpose |
|------|---------|
| `CaptureEngine.swift` | ScreenCaptureKit: freezing displays, listing windows front to back, and single-window capture |
| `SelectionOverlay.swift` | The full-screen selection UI: area, window, magnifier and size readout |
| `CaptureCoordinator.swift` | Runs a capture from shortcut to output; permission handling |
| `CaptureOutput.swift` | Copy, save and drag; on-device text recognition; on-screen messages |
| `QuickAccess.swift` | Corner thumbnails and pinned screenshots |
| `MainWindow.swift` | The SnapStash window: setup and first-run cards, capture buttons, gallery |
| `Library.swift` | Watches the capture folder; actions on saved captures; thumbnail cache |
| `Shortcuts.swift` | Global shortcuts, shown correctly for your keyboard layout |
| `SettingsView.swift` | Settings, including the shortcut recorder |

## Roadmap

- [x] Area, window and screen capture, Quick Access, Pin, Copy Text
- [ ] Annotation: arrows, boxes, text, highlighter, numbered steps, blur, crop
- [ ] Screen recording to MP4 and GIF
- [ ] Scrolling capture

## Releasing

[`build.yml`](.github/workflows/build.yml) builds and verifies the universal app on every push and pull request. Pushing a version tag publishes a GitHub Release with `SnapStash-mac.zip` and its SHA-256 checksum:

```sh
git tag v0.1 && git push origin v0.1
```

## License

[MIT](LICENSE) © Monem Benjeddou

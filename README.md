# MiddleTap

Three-finger **click** or **tap** on the trackpad sends a middle mouse click. It's a menu-bar app with no Dock icon, plus a settings window. Open it from the menu-bar icon → **Settings…**, or by opening MiddleTap from Applications while it is running.

## Build & install

```bash
xcode-select --install        # one time only, if you don't have the Command Line Tools
cd MiddleTap
chmod +x build.sh
./build.sh --install          # builds, copies to /Applications, launches
```

## First run

1. macOS asks for **Accessibility** access. Turn on MiddleTap in System Settings → Privacy & Security → Accessibility. The menu-bar item also has a "Grant Accessibility Permission…" shortcut. MiddleTap starts working within about 2 seconds, so you don't need to relaunch.
2. Open the mouse icon in the menu bar and choose **Launch at Login** if you want it to start automatically.

## Recommended trackpad settings (to avoid conflicts)

- System Settings → Trackpad → Point & Click → **Look up & data detectors**: set it to "Force Click with One Finger", not "Tap with Three Fingers".
- System Settings → Accessibility → Pointer Control → Trackpad Options → **Use trackpad for dragging**: turn this off, or pick a non-three-finger style. Three-finger drag would be turned into a middle-button drag.
- Three-finger swipes (Mission Control, switching Spaces) still work. Finger movement cancels the tap.

## Notes

- **Rebuilding** changes the app's signature, so macOS may silently stop trusting it. If middle click stops working after a rebuild, remove MiddleTap from the Accessibility list, add it back, and relaunch.
- **Tuning:** tap time and movement tolerance are sliders in the settings window.
- **Icon:** `AppIcon.svg` is the source of the app icon, and `AppIcon.icns` is what gets bundled.
- **Private framework:** MiddleTap reads finger counts from Apple's private `MultitouchSupport` framework, the same one MiddleClick and BetterTouchTool use. A future macOS update could break it. If that happens, the app shows an alert instead of misbehaving.
- **External trackpads:** if you connect a Magic Trackpad while MiddleTap is running, choose **Rescan Trackpads**. Trackpads are re-attached automatically after sleep.

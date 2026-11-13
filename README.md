# MacVolume

Keyboard volume control for audio interfaces that macOS can't adjust.

Many USB audio interfaces and DACs (a Focusrite Scarlett, for example) and most HDMI / DisplayPort
monitors don't expose a volume control to macOS. The volume keys do nothing and the menu bar slider is
greyed out. MacVolume is a small menu bar app that gives those devices a software volume, driven by the
normal volume keys.

- Volume up, down and mute keys work, with an on-screen level indicator
- 16 steps like macOS; hold Shift+Option for quarter steps
- Menu bar icon with a slider, mute, and a Launch at Login toggle
- Remembers the level and mute state between launches
- Only takes over when the current output device has no volume control of its own; on built-in
  speakers, AirPods and so on, the keys go to macOS as usual
- No audio driver or kernel extension to install

Built and tested with a 3rd gen Focusrite Scarlett Solo on macOS 26.

## Requirements

- macOS 14.2 or later
- Xcode Command Line Tools (`xcode-select --install`); full Xcode is not needed

## Install

```bash
git clone https://github.com/idlegravity/mac-volume.git
cd mac-volume
./build.sh install
```

This builds `build/MacVolume.app`, copies it to `/Applications` and launches it. Run `./build.sh`
without `install` to build only.

### Permissions

On first launch macOS asks for two permissions:

| Permission | Why | Without it |
| --- | --- | --- |
| System Audio Recording | Capturing the audio so it can be scaled | No sound while the app runs |
| Accessibility | Intercepting the volume keys | Keys don't work; the menu bar slider still does |

Grant Accessibility in System Settings → Privacy & Security → Accessibility. The keys start working a
couple of seconds later; no relaunch is needed.

The app is ad-hoc signed, so macOS ties these permissions to the exact build. After rebuilding from
changed source you will usually be asked again. To avoid that, sign with a real identity:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build.sh install
```

## Usage

| Action | How |
| --- | --- |
| Volume up / down | Volume keys |
| Fine adjustment | Shift+Option + volume keys |
| Mute | Mute key, or the menu |
| Set a level directly | Slider in the menu bar menu |
| Start at login | Launch at Login in the menu |

Volume starts at 100% the first time, so nothing changes until you press a key.

## How it works

The device has no volume control to drive, so MacVolume scales the audio itself before it reaches
the device:

1. A Core Audio **process tap** (`CATapDescription`, macOS 14.2+) captures everything other apps send
   to the output device and mutes the original signal.
2. A private **aggregate device** combines that tap (as an input) with the real device (as the output).
3. An IO callback copies tap → device, multiplying by the current gain. Gain changes are ramped across
   a buffer to avoid clicks.
4. A `CGEventTap` intercepts the system-defined media key events and swallows the volume keys while
   the software volume is active.

The gain is the square of the slider position, which makes the steps sound roughly even.

The engine rebuilds itself when the default output device changes, when the device's sample rate
changes, and after wake from sleep.

| File | Role |
| --- | --- |
| `Sources/MacVolume/AudioEngine.swift` | Process tap, aggregate device, gain |
| `Sources/MacVolume/MediaKeys.swift` | Volume key interception |
| `Sources/MacVolume/HUD.swift` | On-screen level indicator |
| `Sources/MacVolume/AppDelegate.swift` | Menu bar UI, volume state, permissions |
| `Sources/MacVolume/main.swift` | Entry point and `--probe` mode |
| `build.sh` | Builds and signs the `.app` bundle |

### Compared with MonitorControl

[MonitorControl](https://github.com/MonitorControl/MonitorControl) handles the volume keys the same
way, but changes volume by sending DDC commands that tell the monitor's own amplifier to change level.
That only works for displays. An audio interface has no such remote control, so MacVolume has to
scale the audio in software instead.

## Limitations

- **Latency:** audio passes through the app, which adds roughly one IO buffer (about 10 ms).
- **Digital attenuation:** lowering the level in software gives up a little resolution. For best
  results keep the interface's own knob at a sensible level and use MacVolume for everyday changes.
- **Full level if the app stops:** if MacVolume quits or crashes, audio returns to 100% immediately.
- **First output stream only:** the tap covers the device's first output stream, which is the main
  stereo pair on typical interfaces.
- **Recording indicator:** macOS may show its system audio recording indicator while the app runs.

## Troubleshooting

- **No sound while MacVolume is running:** check that it is allowed under System Settings → Privacy &
  Security → Screen & System Audio Recording → System Audio Recording Only. Quitting the app restores
  sound straight away.
- **Volume keys do nothing:** check Accessibility permission. The menu shows a "Grant Accessibility
  Access" item while it is missing.
- **Menu says "using system volume":** the current output device has its own volume control, so
  MacVolume is deliberately staying out of the way.
- **Checking the audio setup:** `/Applications/MacVolume.app/Contents/MacOS/MacVolume --probe` sets up
  the tap and aggregate device, prints what it found, and exits.
- **A refused microphone request in Console:** if the device also has inputs, macOS logs a refused
  microphone request for MacVolume. This is harmless; the app never reads the device's inputs.

## Uninstall

Turn off Launch at Login in the menu, quit the app, then:

```bash
rm -rf /Applications/MacVolume.app
defaults delete com.local.MacVolume
```

## License

[MIT](LICENSE)

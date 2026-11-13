# MacVolume

<img src="Resources/AppIcon.png" width="96" alt="MacVolume icon">

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

### Keeping permissions across rebuilds

By default the app is ad-hoc signed, so macOS ties these permissions to the exact build. After
rebuilding from changed source the old grants stop matching: the volume keys stop working even though
System Settings still shows MacVolume as enabled. Clear the stale entry and relaunch to be asked again:

```bash
tccutil reset Accessibility com.local.MacVolume
```

To avoid this, sign with a fixed identity. macOS then identifies the app by its certificate instead
of by each build's exact contents. A free self-signed certificate is enough.

**1. Create a self-signed certificate**

1. Open Keychain Access.
2. Choose Keychain Access → Certificate Assistant → Create a Certificate…
3. Fill in:
   - Name: `MacVolume Signing` (exactly this; the build script looks for it)
   - Identity Type: Self-Signed Root
   - Certificate Type: Code Signing
4. Click Create and confirm the self-signed warning.

**2. Rebuild with it**

```bash
./build.sh install
```

The first time, macOS asks whether `codesign` may use the key. Enter your login password and choose
Always Allow. The build output should end with `signed with: MacVolume Signing` instead of `ad-hoc`.

**3. Grant permissions one last time**

Switching from the ad-hoc signature to the certificate invalidates the existing grants once more.

```bash
tccutil reset Accessibility com.local.MacVolume
pkill -x MacVolume; open /Applications/MacVolume.app
```

Allow System Audio Recording and Accessibility when asked. Later rebuilds signed with the same
certificate keep both permissions.

To use a different identity, such as an Apple Development certificate:

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
| Reduce latency | Buffer Size in the menu |

Volume starts at 100% the first time, so nothing changes until you press a key.

### Buffer size

Audio makes one extra trip through MacVolume, which adds about one IO buffer of latency. The Buffer
Size submenu sets how big that buffer is; each option shows the latency it adds at the device's
current sample rate.

| Setting | Added latency at 48 kHz |
| --- | --- |
| System Default (usually 512 frames) | 10.7 ms |
| 64 frames | 1.3 ms |
| 128 frames | 2.7 ms |
| 256 frames | 5.3 ms |
| 512 frames | 10.7 ms |
| 1024 frames | 21.3 ms |

Smaller buffers use a little more CPU and are more likely to crackle if the Mac is under heavy load.
If you hear dropouts, pick a larger size. Changing the setting restarts the audio path, which causes a
brief dropout. A size the device doesn't support is clamped to the nearest one it does.

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
| `Scripts/make-icon.swift` | Regenerates `Resources/AppIcon.icns` (`swift Scripts/make-icon.swift`) |

### Compared with MonitorControl

[MonitorControl](https://github.com/MonitorControl/MonitorControl) handles the volume keys the same
way, but changes volume by sending DDC commands that tell the monitor's own amplifier to change level.
That only works for displays. An audio interface has no such remote control, so MacVolume has to
scale the audio in software instead.

## Limitations

- **Latency:** audio passes through the app, which adds roughly one IO buffer (about 10 ms by
  default; see [Buffer size](#buffer-size) to reduce it).
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
  the tap and aggregate device, prints what it found, and exits. Add `--buffer 128` to try a
  buffer size.
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

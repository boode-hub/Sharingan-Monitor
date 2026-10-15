<p align="center">
  <img src="docs/hero.gif" width="900" alt="The Sharingan tray icon awakening from dormant to Mangekyou as CPU load climbs">
</p>

<p align="center">
  <a href="#requirements"><img src="https://img.shields.io/badge/Windows-10%20%7C%2011-C30000?style=for-the-badge&logo=windows&logoColor=white" alt="Windows 10 | 11"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/PowerShell-5.1-8B0000?style=for-the-badge&logo=powershell&logoColor=white" alt="PowerShell 5.1"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-5C0000?style=for-the-badge" alt="MIT license"></a>
  <a href="https://buymeacoffee.com/boode"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-E01B1B?style=for-the-badge&logo=buy-me-a-coffee&logoColor=white" alt="Buy me a coffee"></a>
</p>

<p align="center">
  An animated Sharingan that lives in your Windows system tray and reacts to real system load.<br>
  The eye awakens as your machine works harder: one tomoe, then two, then three, then Mangekyou.<br>
  <b>Pure PowerShell.</b> No installer, no dependencies, no compiled binaries. One script you can read top to bottom.
</p>

## <img src="docs/stage-1.png" width="26" align="top"> Download and install

Nothing to compile and no installer. Never used GitHub before? Just follow along:

<p align="center">
  <img src="docs/download-install.gif" width="900" alt="Code, Download ZIP, Extract All, Run with PowerShell, and the eye in the tray">
</p>

1. Click the green **Code** button near the top of this page, then **Download ZIP**.
2. Right-click the downloaded ZIP, choose **Extract All**, and pick any folder.
3. Open that folder, right-click **Sharingan.ps1**, and choose **Run with PowerShell**
   (on Windows 11 it may sit under **Show more options**).

The eye appears in your system tray straight away. Right-click it for the menu.
A PowerShell window opens with it: minimise it, because closing it closes the eye.
To run it hidden, use the start-at-login option below.

> **If Windows blocks it:** right-click the ZIP *before* extracting, choose
> **Properties**, tick **Unblock**, then extract. Windows flags files downloaded
> from the internet, and this clears that flag.

**Prefer the command line?**

```
powershell -ExecutionPolicy Bypass -File Sharingan.ps1
```

**Want it to start automatically when you log in?**

Double-click `install-startup.bat`. Undo it any time with `remove-startup.bat`,
which also stops the running instance. Neither needs administrator rights.

## <img src="docs/stage-2.png" width="26" align="top"> How it reacts

| CPU / RAM load | | Eye |
| --- | :---: | --- |
| below 15% | <img src="docs/stage-0.png" width="36"> | dormant, no tomoe |
| 15% | <img src="docs/stage-1.png" width="36"> | 1 tomoe |
| 35% | <img src="docs/stage-2.png" width="36"> | 2 tomoe |
| 55% | <img src="docs/stage-3.png" width="36"> | 3 tomoe |
| 75% | <img src="docs/stage-4.png" width="36"> | Mangekyou |

Every threshold is adjustable. Stages blend smoothly rather than snapping — the
morph is a floating-point value and every element scales off it, so the eye grows
into each stage instead of popping.

## <img src="docs/stage-3.png" width="26" align="top"> Using it

Right-click the tray icon:

```
Swap to RAM Tracking       toggle between CPU and RAM
Eyes                    >  Classic  >  the hand-drawn eyes
                        |  V1       >  the artwork eyes (when eyes\ is present)
Customize               >  Thresholds  >  1st / 2nd / 3rd Tomoe, Mangekyou
                        |  Color       >  10 presets + full colour picker
                        |  Speed       >  slider, 0 (paused) to 100
                        |  Direction   >  clockwise / counter-clockwise
                        |  Invert Colors  swap tomoe and eye colour
                        |  Shuffle     >  cycle eyes randomly, on a timer
                        |  Glow        >  on/off, heartbeat pulse, pulse speed
                        |  Profiles    >  save / load a whole set of settings
                        |  Reset to Defaults
Buy me a coffee            opens the support page in your browser
Exit
```

Everything applies live. Settings persist to `settings.json` next to the script.
A profile is the same settings in one small JSON file under `profiles\`.

When load climbs past the last threshold the three tomoe swirl in the direction
the eye is spinning, their tails stretch into long arms, and those arms become
the Mangekyou.

<p align="center">
  <img src="docs/customize.gif" width="900" alt="Using the tray menu: switching eye, colour, speed, glow, then reset">
  <br>
  <em>Every setting lives in the tray menu, no separate settings window.</em>
</p>

## <img src="docs/stage-4.png" width="26" align="top"> The eyes

**Classic**: 18 eyes, all drawn in code.

<p align="center">
  <img src="docs/eyes.png" width="900" alt="The 18 Classic eyes at full Mangekyou">
</p>

**V1** - drawn from artwork you supply in an `eyes\` folder next to the script
(the expected file names are in `$global:EyeFiles` in the script). V1 shows up
in the menu only for the eyes whose file is present; with no `eyes\` folder the
menu simply lists the Classic eyes.

Every eye rotates and grows out of nothing as the stage builds, and shuffle stays
within the set you are on.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (ships with Windows — nothing to install)

## How it works

The interesting parts, if you want to read the source:

- **Load sampling** — `PerformanceCounter("Processor", "% Processor Time", "_Total")`
  for CPU, so the numbers match Task Manager, and `GlobalMemoryStatusEx` for RAM.
- **The morph** — load maps to a target stage, and the current stage eases toward
  it each frame. That easing is why the eye flows between stages.
- **Rendering** — every frame draws a fresh 128×128 bitmap. Tomoe tails and
  Mangekyou blades are runs of overlapping circles, which is crude but
  anti-aliases beautifully.
- **The tray pipeline** — a WinForms `Timer` under a real message pump at ~28fps,
  disposing the previous icon and calling `DestroyIcon` on every frame. Skipping
  that leaks GDI handles until the process dies.

## Support

This is free and always will be — every feature, no paywalls, no nags.

If it made your taskbar better and you'd like to say thanks:

<a href="https://buymeacoffee.com/boode"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-E01B1B?style=for-the-badge&logo=buy-me-a-coffee&logoColor=white" alt="Buy me a coffee"></a>

Entirely optional, and it changes nothing about the software.

## Disclaimer

Unofficial fan software. Not affiliated with, endorsed by, or sponsored by
Masashi Kishimoto, Shueisha, TV Tokyo, or Viz Media.

"Sharingan", "Mangekyou Sharingan" and the character names are the intellectual
property of their respective owners. This project ships **no** artwork, audio or
other assets from any Naruto work — every graphic is generated at runtime by the
drawing code in this repository. The code is MIT licensed; see `LICENSE`.

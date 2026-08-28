# Sharingan Tray Monitor

An animated Sharingan eye that lives in the Windows system tray and reacts to live
system load. The eye evolves through five stages as CPU (or RAM) usage climbs, and
spins faster the harder your machine is working.

Pure PowerShell — no dependencies, no compiled binaries, no installer.
`System.Drawing` (GDI+) for rendering, `System.Windows.Forms` for the tray icon.

## Stages

| Load | Eye |
|---|---|
| below threshold 1 | plain eye, no tomoe |
| threshold 1 | 1 tomoe |
| threshold 2 | 2 tomoe |
| threshold 3 | 3 tomoe |
| threshold 4 | Mangekyou |

Defaults are 15 / 35 / 55 / 75 %, all adjustable. Stages blend smoothly rather than
snapping — the morph stage is a float and every element scales off it.

## Running it

```
powershell -ExecutionPolicy Bypass -File p2.ps1
```

Right-click the tray icon:

```
Swap to RAM Tracking
Eyes         >  18 Sharingan styles
Customize    >  Thresholds  >  1st / 2nd / 3rd Tomoe, Mangekyou
             |  Color       >  10 presets + colour picker
             |  Speed       >  0.20x .. 3.00x
             |  Shuffle     >  on/off + interval
             |  Glow           (brightens the eye colour)
             |  Reset to Defaults
Exit
```

Settings persist to `settings.json` next to the script.

## Start at login

```
install-startup.bat     enable at login and launch now
remove-startup.bat      remove from login and stop the running instance
```

Uses the per-user `HKCU\...\Run` key, so no admin prompt. A generated
`launcher.vbs` shim starts PowerShell fully hidden — `-WindowStyle Hidden` on its
own still flashes a console window at every boot.

## Eyes

Itachi, Obito, Kakashi, Madara, Izuna, Sasuke, Shisui, Indra, Shin, Sarada, Naka,
Baru, Rai, Naori, Fugaku, Nanashi, Madara Eye 2, Sasuke Eye 2.

## Files

| File | Purpose |
|---|---|
| `p2.ps1` | the application |
| `install-startup.bat` / `remove-startup.bat` | login integration |
| `PROJECT_PROMPT.txt` | full build spec — architecture, decisions, and the pitfalls found the hard way |
| `p2.ps1.bak` | original script before any modifications |
| `p2.ps1.pre-eyefix.bak` | state before the eye animation fixes |

## Notes

Sharingan, Mangekyou Sharingan and the character names are the intellectual
property of Masashi Kishimoto / Shueisha. This is a personal, non-commercial
project and is not affiliated with or endorsed by the rights holders.

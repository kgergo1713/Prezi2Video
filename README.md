# Prezi2Video

Converts a Google Slides PDF export into a single looping MP4 file ready for Samsung TV USB playback. No installation required — all dependencies are fetched automatically on first run.

## How it works

```
Google Slides → Download as PDF → double-click konverter.bat → single .mp4 → copy to USB → TV plays on loop
```

Each slide is displayed for 5 seconds. The loop is baked into the file (default: 10 hours), so no TV menu configuration is needed.

## Usage

1. Export your presentation from Google Slides as PDF.
2. Place the PDF in the same folder as `konverter.bat`.
3. Double-click `konverter.bat`.
4. Copy the generated `*_tv.mp4` to a USB drive and plug it into the TV.

To use a different PDF, drag and drop it onto `konverter.bat`.

### Advanced (PowerShell)

```powershell
.\_slides2tv.ps1 -Pdf "deck.pdf" -SecPerSlide 8 -Hours 12 -Rotate cw
```

| Parameter | Default | Description |
|---|---|---|
| `-Pdf` | auto-detected | Path to the input PDF |
| `-SecPerSlide` | `5` | Seconds each slide is displayed |
| `-Hours` | `10` | Total loop duration baked into the file (`0` = single pass) |
| `-Resolution` | `1920x1080` | Output resolution |
| `-Rotate` | `none` | Rotate content: `none`, `cw`, `ccw`, `180` |

## Requirements

- Windows 10 or later
- Internet connection on first run (downloads ffmpeg and poppler, ~130 MB total; cached in `bin\` afterwards)

## Tech stack

- [ffmpeg](https://github.com/BtbN/FFmpeg-Builds) — video encoding
- [poppler for Windows](https://github.com/oschwartz10612/poppler-windows) — PDF to PNG rendering

## Feedback & support

Questions or issues: [kgergo1713@gmail.com](mailto:kgergo1713@gmail.com)

Support the project: [Revolut](https://revolut.me/kgergo1713)

## License

MIT

# slides2tv — PDF → looping MP4 for Samsung TV USB playback (Windows, no-install)

## Goal

A non-technical end user has a Samsung TV (LAN-connected, sitting in a shop window) that plays
looping content from a USB drive. The TV's USB media player **cannot render PPTX/PDF directly**
(image/video only), so the content pipeline is:

```
Google Slides → "Download as PDF" → [this tool] → single .mp4 → copy to USB → TV plays it on loop
```

The end user always exports a fresh PDF from Google Slides themselves. The slide count is
**variable** (changes over time), so the tool must auto-detect it — never hardcode a slide count.
Each slide should display for **5 seconds** by default. The deck's *content* is laid out sideways
inside a landscape PDF on purpose — the physical TV panel is mounted in portrait orientation, so a
landscape frame with rotated content displays upright once physically rotated. **No `-Rotate` flag
needed for this specific deployment** (default `Rotate none` is correct) — this only matters if a
future deck uses true portrait page setup instead.

## Hard constraint: zero technical skill on the end-user side

- No WSL, no terminal usage, no manual installs, no admin rights assumed.
- End user interaction is: **double-click `eloszor.bat`**. That's it.
- `eloszor.bat` defaults to looking for `V1_Master_Template.pptx.pdf` in its own folder (this
  filename is expected to stay constant). If absent, it interactively asks for a path.
- Everything else (fetching ffmpeg/poppler, encoding, looping) must be fully automatic.

## Current file layout (Downloads folder, flat)

```
eloszor.bat          <- user double-clicks this
masodszor.ps1         <- does the actual work; bypasses ExecutionPolicy via the .bat
V1_Master_Template.pptx.pdf   <- the user's exported deck (26 MB, image-heavy, confirmed valid/openable)
bin\                  <- self-provisioned on first run (ffmpeg-bin\, poppler\) — gitignore-style cache
```

## What `masodszor.ps1` does, step by step

1. **Resolve input PDF**: param `-Pdf`, else look for `V1_Master_Template.pptx.pdf` next to the
   script, else interactively `Read-Host`.
2. **Self-provision dependencies** (first run only, cached after):
   - `ffmpeg.exe` ← static build from `https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip`
     (fixed URL, no GitHub API call needed — `releases/download/latest/<fixed-filename>` is stable).
   - `pdftoppm.exe` (poppler) ← resolved via GitHub API
     `https://api.github.com/repos/oschwartz10612/poppler-windows/releases/latest`, then download
     whichever `*.zip` asset is attached (filename varies per release, hence the API call instead
     of a hardcoded URL).
   - Both download as zip, get `Expand-Archive`'d, the actual `.exe` is located with
     `Get-ChildItem -Recurse -Filter`, then copied into a stable `bin\ffmpeg-bin\` /
     `bin\poppler\...` path so subsequent runs skip the network entirely.
   - **No `winget` dependency** — an earlier version used `winget install Gyan.FFmpeg.Essentials`
     but this failed on the user's machine (`HIBA: nincs winget ezen a gepen` — likely a locked-down
     corporate Windows image, possibly without the Microsoft Store/App Installer component). Direct
     zip download replaced it for reliability on locked-down machines.
3. **PDF → PNG**: `pdftoppm -png -r 200 <pdf> <prefix>` into a fresh per-run temp dir
   (`$env:TEMP\slides2tv_<8-char-guid>\`).
4. **Fixed-width renumbering**: `pdftoppm`'s output zero-padding width depends on total page count
   (`slide-1.png` for ≤9 pages vs `slide-01.png` for 10+), which is incompatible with a fixed
   `ffmpeg %0Nd` pattern decided ahead of time. Fix: copy/renumber every PNG to `f-001.png`,
   `f-002.png`, … (always 3 digits) in a `numbered\` subfolder before handing off to ffmpeg.
5. **Encode base deck**: `ffmpeg -framerate 1/$SecPerSlide -i f-%03d.png -vf <scale+pad+format> ...`
   → `base.mp4`. Resulting duration is *exactly* `slide_count * SecPerSlide` (verified — this
   approach is deterministic, unlike an earlier abandoned attempt using the concat demuxer's
   `duration` directive, which under-/over-shot due to filter-chain PTS rounding).
6. **Loop-bake**: stream-copy repeat (`-stream_loop N -c copy`) to reach a target `-Hours` runtime,
   so the shop-window operator never has to find the TV's "Repeat" setting — the loop is baked into
   the file. `-Hours 0` skips baking (single pass-through, rely on TV's native repeat instead).
7. Output: `<stem>_tv.mp4` next to the source PDF.

## Rotation support (`-Rotate none|cw|ccw|180`)

Inserted as an ffmpeg `transpose` filter prepended to the scale/pad chain:
- `cw` → `transpose=1,`
- `ccw` → `transpose=2,`
- `180` → `transpose=2,transpose=2,`
- `none` (default) → no-op

This was validated pixel-by-pixel (corner-sampling a rendered frame) in an earlier Linux-side
prototype: `none` left black pad bars on a portrait-content/landscape-page test image; `cw`
filled the frame edge-to-edge with no padding. Not currently exercised in the Windows version
with real data, but the filter syntax is identical ffmpeg `-vf` syntax, so it should carry over
directly.

## Bugs found and fixed during Windows porting (in chronological order — useful context)

1. **`./slides2tv.sh` doesn't run in PowerShell/cmd** — obviously, bash syntax. Original tool was a
   bash script (Linux/WSL only); this `.ps1`/`.bat` pair is the from-scratch Windows port.
2. **`winget` not present on the target machine** → switched ffmpeg provisioning from
   `winget install` to direct static-zip download (see step 2 above).
3. **`-pattern_type glob` not supported by this ffmpeg build**: error was
   `Pattern type 'glob' was selected but globbing is not supported by this libavformat build`.
   The BtbN static build apparently isn't compiled with glob support. Fixed by switching from
   `-pattern_type glob -i 'slide-*.png'` to the fixed-width-renumber approach (step 4 above),
   which needs no glob support at all — just standard `%03d` sequential numbering.
4. **`$ErrorActionPreference = "Stop"` caused false-positive crashes**: poppler's `pdftoppm`
   emits harmless warnings to stderr (`Syntax Error (NNNN): Singular matrix in tiling pattern
   fill` — repeated many times, one per affected tiling-pattern fill in the PDF; this is a
   poppler quirk with certain pattern-fill constructs, NOT a real failure — the PNGs still
   generate correctly and the slide count came out right when this was visible). With
   `ErrorActionPreference = Stop`, **any** stderr write from a native exe makes PowerShell throw
   `NativeCommandError` and abort the whole script, regardless of the process's actual exit code.
   Fixed by setting `$ErrorActionPreference = "Continue"` globally and relying exclusively on
   explicit exit-code checks after each native call (which were already present).
5. **Silent multi-minute hang perception**: `pdftoppm`/`ffmpeg` give no progress output during a
   long operation (large image-heavy PDF at 200 DPI took ~1 minute), and with output suppressed
   the user couldn't tell a slow run from a hang. Fixed by wrapping long native calls in
   `Invoke-WithSpinner` — runs the native exe via `Start-Job`, polls `$job.State` every 400ms while
   printing a `| / - \` spinner to the same line (`Write-Host -NoNewline "`r..."`), then resolves
   the job and returns `[exit code, full output]`.
6. **Output was fully suppressed even on real failure**: the spinner helper originally redirected
   `*>$null`, which also hid genuine error messages, making `exit 1` failures undiagnosable from
   user-supplied screenshots. Fixed: capture stdout+stderr into a string inside the job, return it
   alongside the exit code, and print it (clearly bounded by `--- a program reszletes kimenete
   ---` markers) **only when exit code is non-zero** — keeps successful runs clean, makes failed
   runs diagnosable.

## UNRESOLVED — the actual open bug at handoff time

After fix #6 was shipped, the real underlying pdftoppm error surfaced:

```
pdftoppm.exe : Syntax Error: Document stream is empty
```
with exit code 1.

**This is intermittent and not yet root-caused.** Timeline of observations:

- Run A: failed with this exact error (first time fix #6's diagnostic output was visible).
- Run B (immediately after, same machine, same PDF, without changing anything the user is aware
  of): **succeeded** — produced a working `_tv.mp4` that the user confirmed plays correctly with
  correct slide content and timing.
- Run C (a repeat requested specifically to confirm stability): **failed again**, with poppler
  re-downloading from scratch first (`>> pdftoppm (poppler) hianyzik -> letoltes GitHub-rol`) —
  meaning the previously-provisioned `bin\poppler\` directory was *not* found/reused on this run,
  despite Run B having presumably gone through `Ensure-Pdftoppm`'s provisioning and caching path
  just before.

Key facts ruled out so far:
- **Not a corrupt source PDF**: user confirmed the PDF opens fine, is a sane size (26,302 KB), and
  was produced via the expected Google Slides → Download → PDF flow. `dir` confirms the script is
  resolving the exact right file path.
- **Not (purely) the harmless tiling-pattern warnings**: those are a separate, cosmetic,
  known-benign issue (fix #4/#6 already accounts for them).

Leading hypotheses, **not yet confirmed**:
1. **Poppler zip caching/extraction race or partial state**: the `bin\poppler\` cache check
   (`Test-Path (Join-Path $BinDir "poppler\Library\bin\pdftoppm.exe")`) may be passing against a
   leftover *partial* extraction from an earlier interrupted/failed run, leaving a `pdftoppm.exe`
   present but missing sibling files it depends on at runtime (e.g. shared DLLs, or the
   `poppler-data` encoding/font-substitution resources that ship alongside `Library\bin\` in the
   oschwartz10612 package — these typically live under a sibling `Library\share\poppler\` or similar
   relative to the exe; if `Copy-Item`/extraction didn't bring those along intact, certain PDFs —
   particularly ones with embedded fonts/encodings exercising those data files — could plausibly
   produce confusing "stream is empty"-style errors instead of a clearer "missing resource" error).
   This would also explain the intermittency: a *fresh, complete* re-download (as happened in Run C)
   should be self-consistent, yet Run C *also failed*, which weakens this theory somewhat — unless
   the zip itself, or the extraction logic, deterministically produces an incomplete layout every
   time, and Run B's success was for some *other* reason (see hypothesis 3).
2. **Argument-passing/quoting issue specific to `Start-Job`'s `@a` splat inside the background job
   scriptblock**: `Invoke-WithSpinner` runs `& $e @a 2>&1` inside a `Start-Job` child process. Job
   child processes get a fresh PowerShell runspace; if any argument (e.g. the PDF path) round-trips
   through job serialization in a way that subtly mangles it (extra/missing quoting, encoding),
   `pdftoppm` could receive a malformed path and report something like "stream is empty" rather
   than a clean file-not-found. This is specuative and not yet tested directly.
3. **A real, content-specific poppler rendering bug** triggered by something in this particular
   deck (it's confirmed image-heavy, 26 MB, with tiling-pattern fills already known to be
   borderline per the warnings) — possibly a poppler bug where a malformed/edge-case tiling pattern
   fill, beyond the simple matrix-singularity warning, occasionally causes the *content stream
   parser itself* to bail out empty, non-deterministically (e.g. depending on some unstable
   resource limit, memory layout, or processing order). This would explain both the intermittency
   AND why a "harmless" warning and the fatal error appear to be related to the same underlying
   pattern-fill content.

## Next debugging steps (in progress, not yet completed)

We were about to run the **exact same `pdftoppm.exe` invocation manually, directly in a terminal**,
bypassing the PowerShell script entirely, to determine:
- (a) whether manual invocation with the real PDF reproduces the error directly (isolates
  script/job-layer issues vs. poppler/PDF-content issues), and
- (b) whether a **different, simple PDF** through the same `pdftoppm.exe` binary also fails (isolates
  a broken/incomplete poppler install from a PDF-content-specific issue).

Neither test had been run yet when we paused to move to VS Code / Copilot.

## Suggested concrete next actions for Copilot (agent mode)

1. Reproduce locally if possible: pull the same poppler-windows release
   (`oschwartz10612/poppler-windows`, asset matching the user's `Release-26.02.0-0.zip`), extract it,
   and diff its full directory tree against what `Ensure-Pdftoppm` actually leaves behind in
   `bin\poppler\` after extraction+flatten — specifically check whether `Library\share\poppler\`
   (or wherever poppler-data lives in this package layout) survived the `Get-ChildItem -Recurse
   -Filter "pdftoppm.exe" | Select-Object -First 1` + whatever copy step follows it intact, or got
   left behind/orphaned.
2. Run `pdftoppm.exe -v` standalone to sanity-check the binary isn't itself corrupted/incomplete
   (mismatched DLL versions, etc.) — compare against a clean from-scratch extraction.
3. Add a temporary diagnostic: have the script print the **resolved absolute path string exactly as
   it will be passed to `pdftoppm`**, byte-length included, immediately before the `Invoke-WithSpinner`
   call — to rule out any hidden character/encoding mangling in the `$Pdf` variable, especially
   given the job-boundary hypothesis above.
4. Test bypassing `Start-Job` entirely for `pdftoppm` specifically (run it synchronously, foreground,
   no spinner) as an isolation step — if that alone fixes the intermittency, the job/runspace
   boundary is implicated; if it still intermittently fails, the issue is in poppler/the PDF itself.
5. Consider whether retry-with-backoff (re-run `pdftoppm` once automatically on a non-zero exit
   before surfacing an error to the user) is an acceptable pragmatic mitigation if root cause proves
   elusive — given Run B succeeded with zero changes from Run A, a transient race seems plausible
   and a single silent retry might paper over it acceptably for a non-technical end user, though
   this is a workaround, not a fix, and should only be a fallback if root-causing stalls.

## Style/communication notes for continuing this work

- The end user (Gergő) communicates in Hungarian; prior conversation history was conducted in
  Hungarian throughout. Prefers concise, technically dense responses, preserving English technical
  terms inline (this is consistent with established preference from unrelated past conversations).
- He is technically literate (industrial IT/OT background, Docker/CI/CD experience) but the
  **deployment target user is explicitly non-technical** — hence the zero-terminal, double-click-only
  UX constraint described above. Don't relax that constraint when proposing fixes.
- Every fix in this thread was validated empirically before being shipped — either via direct
  Linux-side ffmpeg/poppler reproduction of the relevant logic (when a live Windows test wasn't
  available), or via the user running the actual `.bat`/`.ps1` and reporting back real terminal
  output/screenshots. Avoid proposing speculative fixes presented as definitive without some form
  of validation; flag clearly when something is a hypothesis vs. a confirmed root cause (the
  unresolved bug section above intentionally does this).

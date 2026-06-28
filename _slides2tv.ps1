<#
  _slides2tv.ps1 — PDF -> Samsung TV-safe looping MP4 (USB lejatszas), Windows, telepites nelkul.
  Belso script: kozvetlenul ne inditsd, a konverter.bat hivja meg.

  Alapertelmezesben a sajat mappajabol a "V1_Master_Template.pptx.pdf" fajlt keresi
  (ezt varjuk, hogy nem valtozik). Ha nem talalja, megkerdezi a fajlnevet.

  Mukodes:
    1) Elso futasnal lehuzza maganak az ffmpeg.exe-t (BtbN statikus build, GitHub) es a
       pdftoppm.exe-t (poppler-windows, GitHub release) a .\bin mappaba. Utana offline mukodik.
    2) PDF -> PNG (pdftoppm) -> MP4 (ffmpeg), TV-safe enkodolassal.
    3) A loop-hosszt bele-suti a fajlba (stream-copy ismetles), hogy a kirakatban
       senkinek ne kelljen a TV "Repeat" menujet keresnie.

#>

param(
  [Parameter(Mandatory=$false)] [string]$Pdf,
  [int]$SecPerSlide = 5,
  [double]$Hours = 10,
  [string]$Resolution = "1920x1080",
  [int]$Dpi = 200,
  [int]$Fps = 30,
  [ValidateSet("none","cw","ccw","180")] [string]$Rotate = "none",
  [string]$OutFile = ""
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BinDir    = Join-Path $ScriptDir "bin"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

function Write-Step($msg) { Write-Host ">> $msg" -ForegroundColor Cyan }
function Write-Err($msg)  { Write-Host "HIBA: $msg" -ForegroundColor Red }

# Hatterben futtat egy natic exe-t, kozben pörgő jelet ir ki, hogy a user lassa: dolgozik, nem fagyott le.
# Visszaadja az exit code-ot ES a natic exe teljes kimenetet (stdout+stderr egyutt).
# A kimenetet csak hiba eseten irjuk ki a kepernyore (sikeres futasnal csak zajt jelentene).
function Invoke-WithSpinner {
  param([string]$Exe, [string[]]$CmdArgs)
  # $Args PowerShell automatic variable -> $using:Args a jobban az auto-var-t kapna el, nem a paramtert.
  # Ezert explicit, nem-foglalt nevu valtozokba mentjuk a job elott.
  $jobExe  = $Exe
  $jobArgs = [string[]]$CmdArgs
  $job = Start-Job -ScriptBlock {
    $out = & $using:jobExe @using:jobArgs 2>&1 | Out-String
    [PSCustomObject]@{ Code = $LASTEXITCODE; Output = $out }
  }

  $spinner = @('|','/','-','\')
  $si = 0
  while ($job.State -eq 'Running') {
    Write-Host -NoNewline ("`r   dolgozik... " + $spinner[$si % 4])
    $si++
    Start-Sleep -Milliseconds 400
  }
  Write-Host "`r   kesz.                "
  $result = Receive-Job -Job $job -Wait
  Remove-Job -Job $job
  if ($result.Code -ne 0 -and $result.Output) {
    Write-Host "--- a program reszletes kimenete (hibakereseshez) ---" -ForegroundColor DarkYellow
    Write-Host $result.Output
    Write-Host "--- kimenet vege ---" -ForegroundColor DarkYellow
  }
  return $result.Code
}

# --- 0) Bemenet bekerese ---
# Alapertelmezett fajlnev: ugyanabban a mappaban, ahonnan ezt inditjak, mindig ugyanaz a nev varhato.
$DefaultPdfName = "V1_Master_Template.pptx.pdf"

if (-not $Pdf) {
  $defaultCandidate = Join-Path $ScriptDir $DefaultPdfName
  if (Test-Path $defaultCandidate) {
    $Pdf = $defaultCandidate
    Write-Host "Talalt fajl: $DefaultPdfName"
  } else {
    Write-Host "Nem talalom a megszokott fajlt ($DefaultPdfName) ebben a mappaban."
    Write-Host "Add meg a PDF fajl eleres utjat (vagy huzd ra a .bat-ra a fajlt):"
    $Pdf = Read-Host "PDF utvonal"
  }
}
$Pdf = $Pdf.Trim('"')
if (-not (Test-Path $Pdf)) { Write-Err "nincs ilyen fajl: $Pdf"; exit 1 }
$Pdf = (Resolve-Path $Pdf).Path

if (-not $OutFile) {
  $stem = [System.IO.Path]::GetFileNameWithoutExtension($Pdf)
  $OutFile = Join-Path (Split-Path $Pdf -Parent) "${stem}_tv.mp4"
}

# ============================================================
# 1) FUGGOSEGEK ELOKESZITESE (egyszeri, utana cache-elt a .\bin alatt)
# ============================================================

function Ensure-Ffmpeg {
  $exe = Join-Path $BinDir "ffmpeg-bin\ffmpeg.exe"
  if (Test-Path $exe) { return $exe }

  $sys = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
  if ($sys) { Write-Step "ffmpeg mar telepitve a rendszeren, azt hasznalom"; return $sys.Source }

  Write-Step "ffmpeg hianyzik -> letoltes (egyszeri, internet kell, ~80-100 MB)"
  $url = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
  $zipPath = Join-Path $BinDir "ffmpeg.zip"
  try {
    Invoke-WebRequest -Uri $url -OutFile $zipPath -Headers @{ "User-Agent" = "masodszor-script" }
  } catch {
    Write-Err "nem sikerult letolteni az ffmpeg-et. Internetkapcsolat vagy tuzfal/proxy blokk? $($_.Exception.Message)`nKezi megoldas: tolts le egy build-et innen: https://www.gyan.dev/ffmpeg/builds/ , es masold a ffmpeg.exe-t ide: $(Join-Path $BinDir 'ffmpeg-bin')"
    exit 1
  }

  $extractDir = Join-Path $BinDir "ffmpeg-extract"
  if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
  Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
  Remove-Item $zipPath -Force

  $found = Get-ChildItem -Path $extractDir -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
  if (-not $found) { Write-Err "a kicsomagolt ffmpeg csomagban nincs ffmpeg.exe (csomag-szerkezet valtozott?)"; exit 1 }

  # athelyezes egy stabil bin\ffmpeg-bin mappaba, hogy a kovetkezo futasnal azonnal megtalaljuk
  $targetDir = Join-Path $BinDir "ffmpeg-bin"
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
  Copy-Item (Join-Path $found.DirectoryName "*") $targetDir -Recurse -Force
  Remove-Item $extractDir -Recurse -Force

  $finalExe = Join-Path $targetDir "ffmpeg.exe"
  Write-Step "ffmpeg keszen all: $finalExe"
  return $finalExe
}

function Ensure-Pdftoppm {
  # Dinamikus kereses: a zip belso mappanevtol fuggetlenul megtalaljuk (pl. Release-26.02.0-0\Library\bin\)
  $popplerDir = Join-Path $BinDir "poppler"
  if (Test-Path $popplerDir) {
    $cached = Get-ChildItem -Path $popplerDir -Recurse -Filter "pdftoppm.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cached) { return $cached.FullName }
  }

  $sys = Get-Command pdftoppm.exe -ErrorAction SilentlyContinue
  if ($sys) { Write-Step "pdftoppm mar telepitve a rendszeren, azt hasznalom"; return $sys.Source }

  Write-Step "pdftoppm (poppler) hianyzik -> letoltes GitHub-rol (egyszeri, internet kell)"
  $api = "https://api.github.com/repos/oschwartz10612/poppler-windows/releases/latest"
  try {
    $rel = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "masodszor-script" }
  } catch {
    Write-Err "nem sikerult elerni a GitHub API-t poppler letoltesehez. Internetkapcsolat? $($_.Exception.Message)"
    exit 1
  }
  $asset = $rel.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
  if (-not $asset) { Write-Err "nem talalok poppler .zip assetet a release-ben"; exit 1 }

  $zipPath = Join-Path $BinDir "poppler.zip"
  Write-Step "letoltes: $($asset.name)"
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers @{ "User-Agent" = "masodszor-script" }

  $extractDir = Join-Path $BinDir "poppler"
  if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
  Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
  Remove-Item $zipPath -Force

  $found = Get-ChildItem -Path $extractDir -Recurse -Filter "pdftoppm.exe" | Select-Object -First 1
  if (-not $found) { Write-Err "a kicsomagolt poppler-ben nincs pdftoppm.exe (csomag-szerkezet valtozott?)"; exit 1 }

  # App-local MSVC runtime: a poppler zip nem tartalmaz vcruntime140*.dll / msvcp140.dll -t.
  # Ha ezek hianyzanak a poppler \bin\ mellol, az exe 0xC0000135 hibával indul el.
  # Masolunk System32-bol (engedett: MS Redistributable license), ha ott vannak.
  # Ha System32-ben sincs (teljesen friss Windows, sosem telepitett VC++ app),
  # letoltjuk a Microsoft VC++ 2015-2022 Redistributable-t.
  $popplerBin = Split-Path $found.FullName
  $runtimeDlls = @("vcruntime140.dll","vcruntime140_1.dll","msvcp140.dll","msvcp140_1.dll")
  $missingFromSys = @()
  foreach ($dll in $runtimeDlls) {
    if (Test-Path (Join-Path $popplerBin $dll)) { continue }
    $sys = Join-Path $env:SystemRoot "System32\$dll"
    if (Test-Path $sys) { Copy-Item $sys $popplerBin -Force }
    else                { $missingFromSys += $dll }
  }
  if ($missingFromSys.Count -gt 0) {
    Write-Step "Visual C++ futtatokornyzet letoltese (vcredist, ~25 MB) - egyszeri, admin jog kell"
    $vcExe = Join-Path $BinDir "vcredist.exe"
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $vcExe `
      -Headers @{ "User-Agent" = "slides2tv" }
    Start-Process $vcExe -ArgumentList "/install /quiet /norestart" -Wait
    Remove-Item $vcExe -Force -ErrorAction SilentlyContinue
    foreach ($dll in $missingFromSys) {
      $sys = Join-Path $env:SystemRoot "System32\$dll"
      if (Test-Path $sys) { Copy-Item $sys $popplerBin -Force }
    }
  }

  Write-Step "poppler keszen all: $($found.FullName)"
  return $found.FullName
}

$Ffmpeg    = Ensure-Ffmpeg
$Pdftoppm  = Ensure-Pdftoppm

# ============================================================
# 2) MUNKAMAPPA
# ============================================================

$Work = Join-Path $env:TEMP ("slides2tv_" + [System.Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Force -Path $Work | Out-Null
try {

  $W,$H = $Resolution -split "x"

  # --- 3) PDF -> PNG ---
  Write-Step "pdf -> png @ $Dpi DPI (nagy/sok-kepes PDF-nel ez eltarthat tobb percig is!)"
  Write-Host "   PDF: $Pdf" -ForegroundColor DarkGray
  $slidePrefix = Join-Path $Work "slide"
  # a poppler "Singular matrix in tiling pattern fill" tipusu uzenetei artalmatlanok
  # (egy mintazat/textura kitoltest hagy ki, a tobbi tartalom jo marad) -> elnemitva,
  # mert csak zavarna a usert; a tenyleges sikert a exit code + kep-szam=0 ellenorzes donti el.
  $pdftoppmArgs = @("-png","-r",$Dpi,$Pdf,$slidePrefix)
  # System.Diagnostics.Process kozvetlenul: Start-Process -PassThru PS5.1-ben null ExitCode-ot adhat
  # vissza, ami ($null -ne 0) = TRUE, tehat hamis hibat triggerel. Process.Start() + WaitForExit()
  # garantaltan helyes ExitCode-ot ad. ReadToEndAsync(): aszinkron stderr-olvasas megelozi a
  # buffer-feltolodest (sok "Singular matrix" sor) ami kulonben deadlock-ot okozna.
  $argStr = ($pdftoppmArgs | ForEach-Object {
    $s = [string]$_
    if ($s -match ' ') { '"' + $s + '"' } else { $s }
  }) -join ' '
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName        = $Pdftoppm
  $psi.Arguments       = $argStr
  $psi.UseShellExecute = $false
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow  = $true
  $proc        = [System.Diagnostics.Process]::Start($psi)
  $stderrAsync = $proc.StandardError.ReadToEndAsync()
  $spinner = @('|','/','-','\')
  $si = 0
  while (-not $proc.HasExited) {
    Write-Host -NoNewline ("`r   Feldolgozas... " + $spinner[$si % 4])
    $si++
    Start-Sleep -Milliseconds 400
  }
  $proc.WaitForExit()
  Write-Host "`r                              "
  $exitCode   = $proc.ExitCode
  $stderrText = $stderrAsync.GetAwaiter().GetResult()
  $pdfOut     = if ($stderrText) { $stderrText -split "`r?`n" | Where-Object { $_ } } else { @() }
  if ($exitCode -ne 0) {
    $realErrors = @($pdfOut | Where-Object { $_ -notmatch "Singular matrix in tiling pattern fill" })
    if ($realErrors.Count -gt 0) {
      Write-Host "--- pdftoppm kimenet ---" -ForegroundColor DarkYellow
      $realErrors | ForEach-Object { Write-Host "$_" }
      Write-Host "--- vege ---" -ForegroundColor DarkYellow
    }
    Write-Err "pdftoppm hiba (exit $exitCode)"; exit 1
  }

  $pngs = Get-ChildItem -Path $Work -Filter "slide-*.png" | Sort-Object Name
  if ($pngs.Count -eq 0) { Write-Err "nem keletkezett dia-kep, ellenorizd a PDF-et"; exit 1 }
  Write-Host "   $($pngs.Count) dia, $SecPerSlide mp/dia"

  # a pdftoppm szamozasi szelesseg a diaszamtol fugg (1-9 dia: 'slide-1.png', 10+: 'slide-01.png', stb.),
  # ami ffmpeg %0Nd mintahoz elore nem ismert -> fix 3-jegyu sorszamra atnevezve, build-fuggetlenul biztos.
  $numbered = Join-Path $Work "numbered"
  New-Item -ItemType Directory -Force -Path $numbered | Out-Null
  $i = 1
  foreach ($png in $pngs) {
    Copy-Item $png.FullName (Join-Path $numbered ("f-{0:D3}.png" -f $i))
    $i++
  }

  # --- 4) forgatas (opcionalis) + alap-deck enkodolas ---
  $rotFilter = switch ($Rotate) {
    "cw"   { "transpose=1," }
    "ccw"  { "transpose=2," }
    "180"  { "transpose=2,transpose=2," }
    default { "" }
  }
  $vf = "${rotFilter}scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:color=black,format=yuv420p"

  Write-Step "enkodolas (alap-deck)"
  $base = Join-Path $Work "base.mp4"
  $numericPattern = Join-Path $numbered "f-%03d.png"

  $encArgs = @("-y","-loglevel","error","-framerate","1/$SecPerSlide","-i",$numericPattern,
               "-vf",$vf,"-c:v","libx264","-profile:v","high","-level","4.0","-preset","medium",
               "-crf","23","-r",$Fps,"-pix_fmt","yuv420p",$base)
  $exitCode = Invoke-WithSpinner -Exe $Ffmpeg -CmdArgs $encArgs
  if ($exitCode -ne 0) { Write-Err "ffmpeg enkodolasi hiba (exit $exitCode)"; exit 1 }

  # base.mp4 hossza pontosan: dia-szam * SecPerSlide (determinisztikus, nincs kerekitesi hiba)
  $baseDur = $pngs.Count * $SecPerSlide

  # --- 5) loop bele-sutese ---
  if ($Hours -le 0) {
    Copy-Item $base $OutFile -Force
    Write-Step "egyszeri vegigjatszas (kapcsold be a TV Repeat-jet a vegtelenitesehez)"
  } else {
    $targetSec = $Hours * 3600
    $plays = [Math]::Ceiling($targetSec / $baseDur)
    $loops = [Math]::Max(0, $plays - 1)
    Write-Step "loop bele-sutese: $Hours ora ($plays x ismetles)"
    $loopArgs = @("-y","-loglevel","error","-stream_loop",$loops,"-i",$base,"-c","copy",$OutFile)
    $exitCode = Invoke-WithSpinner -Exe $Ffmpeg -CmdArgs $loopArgs
    if ($exitCode -ne 0) { Write-Err "ffmpeg loop-bake hiba (exit $exitCode)"; exit 1 }
  }

  $sizeMB = [Math]::Round((Get-Item $OutFile).Length / 1MB, 1)
  Write-Host ""
  Write-Host ">> KESZ: $OutFile  ($sizeMB MB)" -ForegroundColor Green
  Write-Host "   Masold USB-re, a TV-n: Source -> USB -> nyisd meg ezt az egy fajlt." -ForegroundColor Green

} finally {
  Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
}

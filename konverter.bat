@echo off
setlocal
rem konverter.bat — dupla-kattintva inditja a konverziot.
rem Alapertelmezesben a "V1_Master_Template.pptx.pdf" fajlt keresi ugyanebben a mappaban.
rem Ha mast szeretnel hasznalni, huzd ra ezt a .bat fajlt a kivant PDF-re.

set "PDFFILE=%~1"

if "%PDFFILE%"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_slides2tv.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_slides2tv.ps1" -Pdf "%PDFFILE%"
)

echo.
echo Nyomj egy gombot a bezarashoz...
pause >nul

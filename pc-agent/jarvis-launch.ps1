$ErrorActionPreference = 'SilentlyContinue'
# 1) Backend starten, falls nicht laeuft
$up = $false
try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', 8900); $up = $c.Connected; $c.Close() } catch {}
if (-not $up) {
  Start-Process -WindowStyle Hidden 'C:\Users\USER\AppData\Local\Programs\Python\Python312\pythonw.exe' `
    -ArgumentList '"C:\Users\USER\jarvis-agent\jarvis-console.py"'
  Start-Sleep -Seconds 3
}
# 2) Browser im App-Modus (Chrome bevorzugt wegen Sprach-Erkennung, sonst Edge)
$cands = @(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
)
$browser = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { Start-Process 'http://127.0.0.1:8900'; return }
Start-Process $browser -ArgumentList @(
  '--app=http://127.0.0.1:8900',
  '--window-size=1340,900',
  "--user-data-dir=$env:LOCALAPPDATA\JarvisApp"
)

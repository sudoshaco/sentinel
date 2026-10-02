param([switch]$Watch)
$ErrorActionPreference = 'Continue'
$PY       = "C:\Users\USER\AppData\Local\Programs\Python\Python312\python.exe"
$INTAKE   = "C:\Users\USER\jarvis-agent\voice-intake"
$DONE     = "$INTAKE\done"
$WOCHE    = "C:\Users\USER\Obsidian\vault\Coach\Woche.md"
$SYNC     = "C:\Users\USER\Obsidian\vault-sync.ps1"
$INTAKEPY = "C:\Users\USER\jarvis-agent\jarvis-voice-intake.py"
$GOTIFY   = "http://100.82.245.85:8080"
$APP      = ((Get-Content "$PSScriptRoot\gotify_app_token" -Raw -ErrorAction SilentlyContinue) + "").Trim()
$LOG      = "C:\Users\USER\jarvis-agent\voice-watcher.log"
New-Item -ItemType Directory -Force $INTAKE,$DONE | Out-Null
function Log($m){ Add-Content $LOG ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$m) -Encoding utf8; Write-Output $m }

# UTF-8 ohne BOM anhaengen (PS5.1 Add-Content -utf8 schleust BOMs ein -> korrumpiert)
function Append-Utf8NoBom($path, $text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::AppendAllText($path, "`r`n" + $text, $enc)
}

function Process-Once {
  $files = Get-ChildItem $INTAKE -File -EA SilentlyContinue | Where-Object { $_.Extension -in '.wav','.txt' }
  foreach ($f in $files) {
    try {
      $out = Join-Path $env:TEMP ("vi-" + $f.BaseName + ".txt")
      if (Test-Path $out) { Remove-Item $out -Force }
      & $PY $INTAKEPY $f.FullName $out 2>$null | Out-Null
      $line = if (Test-Path $out) { (Get-Content $out -Raw -Encoding UTF8).Trim() } else { "" }
      if ($line) {
        Append-Utf8NoBom $WOCHE $line
        & powershell -NoProfile -ExecutionPolicy Bypass -File $SYNC -Quiet 2>$null | Out-Null
        try {
          Invoke-RestMethod "$GOTIFY/message?token=$APP" -Method Post -TimeoutSec 12 `
            -Body @{ title = "Notiz uebernommen"; message = $line; priority = 4 } | Out-Null
        } catch {}
        Log "OK: $line"
      } else { Log "WARN: keine Zeile fuer $($f.Name)" }
      Move-Item $f.FullName (Join-Path $DONE $f.Name) -Force
    } catch { Log "FEHLER $($f.Name): $($_.Exception.Message)" }
  }
}

if ($Watch) { Log "voice-watcher Watch-Modus"; while ($true) { Process-Once; Start-Sleep -Seconds 15 } }
else { Process-Once }

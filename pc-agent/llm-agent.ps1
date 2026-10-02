<#
  llm-agent.ps1  -  Windows-Pull-Agent fuer Jarvis' lokales LLM (Ollama)
  ----------------------------------------------------------------------
  Schwester von crack-agent.ps1 (gleiche Wake-/Pull-/Zock-Mechanik), aber:
    - eigene Queue:  ax:/mnt/queue/llm-pending/*.json  ->  /mnt/queue/llm-done/
    - rechnet mit Ollama (lokal, GPU) statt hashcat
  Ablauf beim Boot (Scheduled Task, User 'USER', "run whether logged on or not"):
    1. wartet bis Tailscale oben ist
    2. wartet bis Ollama-API (127.0.0.1:11434) antwortet
    3. holt Jobs aus  ax:/mnt/queue/llm-pending/*.json  (via Tailscale-SSH)
    4. schickt prompt/system an Ollama -> Antworttext
    5. schreibt Ergebnis nach  ax:/mnt/queue/llm-done/<id>.json  (n8n holt es ab)
    6. Queue leer + unbeaufsichtigt (per WoL hochgekommen) -> PC faehrt herunter
       Angemeldeter Benutzer (du zockst) -> NIEMALS Shutdown.

  Job-JSON (llm-pending/<id>.json):
    { "id":"...", "model":"qwen2.5:7b-instruct"(optional),
      "system":"..."(optional), "prompt":"...",
      "options": { "temperature":0.7, "num_predict":400 }(optional) }
  Ergebnis-JSON (llm-done/<id>.json):
    { "id":"...", "ok":true/false, "response":"...", "model":"...",
      "doneAt":"<ISO>", "host":"<PC>" }

  Parameter:
    -TestOnce     : Queue EINMAL abarbeiten, dann beenden. Niemals Shutdown. (Testlauf)
    -NoShutdown   : normal pollen, aber am Ende NIE herunterfahren.
  Kill-Switch (Datei): existiert  C:\Users\USER\jarvis-agent\NO_SHUTDOWN
    -> Agent faehrt space NIE herunter (fuer Phasen, in denen der PC erreichbar bleiben muss,
       z.B. Remote-Session vom Handy). Datei loeschen = Produktivbetrieb mit Auto-Shutdown.
#>
param(
  [switch]$TestOnce,
  [switch]$NoShutdown,
  [switch]$Watch
)

# =================== KONFIG ===================
$AxHost      = "100.79.252.25"                 # ax = Proxmox, Tailscale-IP
$AxUser      = "root"
$IsSystem    = ([Security.Principal.WindowsIdentity]::GetCurrent()).IsSystem
$SshKey      = if ($IsSystem) { "C:\Windows\System32\config\systemprofile\.ssh\wificatcher_ed25519" } else { "C:\Users\USER\.ssh\wificatcher_ed25519" }
$KnownHosts  = if ($IsSystem) { "C:\Windows\System32\config\systemprofile\.ssh\known_hosts" }        else { "C:\Users\USER\.ssh\known_hosts" }

$OllamaUrl   = "http://127.0.0.1:11434"
$DefaultModel= "qwen2.5:7b"
$LogFile     = "C:\Users\USER\jarvis-agent\llm-agent.log"

$PendingDir  = "/mnt/queue/llm-pending"
$DoneDir     = "/mnt/queue/llm-done"

$ShutdownWhenDone = $true
$ShutdownDelaySec = 60
$EmptyChecks      = 3
$PollSeconds      = 20
# WoL-Fix: Statt "shutdown /s" (S5 - WoL hier unzuverlaessig, Magic-Packet weckt nicht)
# geht der Agent in den S3-Schlaf (WoL erprobt, siehe Realtek-Wake 29.09.).
#   "Sleep"    = S3-Standby (Standard, WoL-sicher, kein Admin noetig)
#   "Shutdown" = altes Verhalten (shutdown /s -> S5)
$SuspendMode      = "Sleep"
# =============================================

function Log($msg) {
  $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
  Write-Output $line
  try { Add-Content -Path $LogFile -Value $line -Encoding utf8 } catch {}
}

# S3-Schlaf statt Shutdown. Weck-Events AKTIV lassen (3. Param = $false) -> WoL kann wecken.
# Fallback auf shutdown /s, falls SetSuspendState fehlschlaegt.
function Suspend-System {
  param([int]$DelaySec = 0)
  if ($DelaySec -gt 0) {
    Log "S3-Schlaf in $DelaySec s (Abbruch: Task beenden / NO_SHUTDOWN anlegen)."
    Start-Sleep -Seconds $DelaySec
    if (Test-Path (Join-Path (Split-Path $LogFile) "NO_SHUTDOWN")) {
      Log "  NO_SHUTDOWN waehrend Wartezeit angelegt -> Schlaf abgebrochen, bleibe an."; return
    }
  }
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Log "  -> gehe in S3-Schlaf (WoL bleibt aktiv)."
    [void][System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $false, $false)
  } catch {
    Log "  WARN: Suspend fehlgeschlagen ($($_.Exception.Message)) -> Fallback shutdown /s /t 5"
    & shutdown /s /t 5 /c "Jarvis LLM-Agent: Suspend fehlgeschlagen, fahre herunter."
  }
}

# Ist ein Mensch interaktiv angemeldet? (PC MANUELL gestartet -> zocken) -> kein Shutdown.
function Test-InteractiveUser {
  try {
    $q = quser 2>$null
    if ($LASTEXITCODE -eq 0 -and $q) {
      $rows = @($q | Select-Object -Skip 1 | Where-Object { $_.Trim() -ne "" })
      if ($rows.Count -gt 0) { return $true }
    }
  } catch {}
  try {
    $exp = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)
    foreach ($p in $exp) {
      $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction SilentlyContinue
      if ($o -and $o.User -and $o.User -ne "SYSTEM") { return $true }
    }
  } catch {}
  return $false
}

function Wait-Tailscale {
  $ts = "C:\Program Files\Tailscale\tailscale.exe"
  if (-not (Test-Path $ts)) { Log "WARN: tailscale.exe nicht gefunden"; return }
  for ($i = 0; $i -lt 30; $i++) {
    $s = (& $ts status 2>&1 | Out-String)
    if ($s -notmatch "NoState|is starting") { Log "Tailscale ist oben"; return }
    Start-Sleep -Seconds 5
  }
  Log "WARN: Tailscale-Status nach Wartezeit unklar - versuche trotzdem"
}

function Wait-Ollama {
  for ($i = 0; $i -lt 30; $i++) {
    try {
      $r = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -TimeoutSec 5 -ErrorAction Stop
      Log "Ollama-API ist oben ($(@($r.models).Count) Modelle lokal)"
      return $true
    } catch { Start-Sleep -Seconds 4 }
  }
  Log "WARN: Ollama-API nach Wartezeit nicht erreichbar"
  return $false
}

# ---- SSH zu ax (robuster Aufruf mit Timeout + Retry, wie im crack-agent) ----
function _sshArgs {
  @('-i', $SshKey, '-o', 'IdentitiesOnly=yes', '-o', "UserKnownHostsFile=$KnownHosts",
    '-o', 'StrictHostKeyChecking=accept-new', '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3', "$AxUser@$AxHost")
}
$SshTimeoutSec = 60; $SshRetries = 3; $SshRetryWait = 5
function Invoke-SshRaw {
  param([string]$RemoteCmd)
  $sa = @(_sshArgs)
  $argString = ($sa | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $argString += ' "' + ($RemoteCmd -replace '"','\"') + '"'
  for ($attempt = 1; $attempt -le $SshRetries; $attempt++) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'ssh'; $psi.Arguments = $argString
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if ($proc.WaitForExit($SshTimeoutSec * 1000)) {
      $out = $outTask.Result
      if ($proc.ExitCode -eq 0) { return @{ ok = $true; out = $out } }
      Log ("  SSH Exit {0} (Versuch {1}/{2}): {3}" -f $proc.ExitCode, $attempt, $SshRetries, ($errTask.Result).Trim())
    } else {
      try { $proc.Kill() } catch {}
      Log ("  SSH Timeout nach {0}s -> ssh gekillt (Versuch {1}/{2})" -f $SshTimeoutSec, $attempt, $SshRetries)
    }
    Start-Sleep -Seconds $SshRetryWait
  }
  return @{ ok = $false; out = '' }
}
function Ax($cmd) {
  $r = Invoke-SshRaw $cmd
  if (-not $r.ok) { return $null }
  return ($r.out -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne '' })
}
# Datei remote schreiben ohne BOM/Quoting-Aerger: base64 lokal -> decode auf ax.
function AxPut($remotePath, $content) {
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
  return (Invoke-SshRaw "echo $b64 | base64 -d > '$remotePath'").ok
}

# ---- Ollama-Aufruf ----
function Invoke-Ollama {
  param([string]$Model, [string]$Prompt, [string]$System, $Options)
  $body = @{ model = $Model; prompt = $Prompt; stream = $false }
  if ($System) { $body.system = $System }
  if ($Options) { $body.options = $Options }
  $json = $body | ConvertTo-Json -Depth 6
  try {
    $r = Invoke-RestMethod -Uri "$OllamaUrl/api/generate" -Method Post -Body $json -ContentType "application/json" -TimeoutSec 300 -ErrorAction Stop
    return @{ ok = $true; text = $r.response }
  } catch {
    return @{ ok = $false; text = ("Ollama-Fehler: " + $_.Exception.Message) }
  }
}

function Process-Job($file) {
  $raw = Ax "cat '$PendingDir/$file'"
  if (-not $raw) { Log "Job $file leer/nicht lesbar"; return $false }
  try { $job = ($raw -join "`n") | ConvertFrom-Json } catch { Log "Job $file kein valides JSON"; return $false }

  $model = if ($job.model) { $job.model } else { $DefaultModel }
  Log "=== LLM-Job $($job.id)  model=$model ==="
  $res = Invoke-Ollama -Model $model -Prompt $job.prompt -System $job.system -Options $job.options
  if ($res.ok) { Log "  Antwort erhalten ($(($res.text).Length) Zeichen)" }
  else         { Log "  FEHLER: $($res.text)" }

  $result = [ordered]@{
    id       = $job.id
    ok       = [bool]$res.ok
    response = $res.text
    model    = $model
    doneAt   = (Get-Date -Format "o")
    host     = $env:COMPUTERNAME
    notify   = [bool]$job.notify           # fire-and-forget -> llm-notify-result (n8n) pusht nach Gotify
    title    = $job.title                  # optionaler Push-Titel
    priority = $job.priority               # optionale Gotify-Prioritaet
  }
  $resultJson = ($result | ConvertTo-Json -Compress -Depth 6)
  if (AxPut "$DoneDir/$($job.id).json" $resultJson) {
    Ax "rm -f '$PendingDir/$file'" | Out-Null
    Log "  Ergebnis -> $DoneDir/$($job.id).json"
    return $true
  } else {
    Log "  WARN: Ergebnis-Upload fehlgeschlagen -> Job bleibt in pending (Retry)"
    return $false
  }
}

# --- Shutdown-Regeln (wie crack-agent) ---
$ShutdownOnlyIfUnattended = $true
$RequireJobToShutdown     = $true

# Koexistenz mit dem crack-agent: NICHT herunterfahren, solange die Crack-Pipeline
# noch arbeitet (hashcat laeuft ODER /mnt/queue/pending nicht leer). Verhindert,
# dass der LLM-Agent einen laufenden Crack-Job abwuergt.
function Test-CrackBusy {
  try { if (@(Get-Process -Name hashcat -ErrorAction SilentlyContinue).Count -gt 0) { return $true } } catch {}
  $crackList = @(Ax "ls -1 /mnt/queue/pending/ 2>/dev/null" | Where-Object { $_ -match '\.json$' })
  if ($crackList.Count -gt 0) { return $true }
  return $false
}

# ===================== MAIN =====================
New-Item -ItemType Directory -Force (Split-Path $LogFile) | Out-Null
$jobsProcessed = 0
if ($TestOnce) { $EmptyChecks = 1; $PollSeconds = 2 }
Log "######## llm-agent Start ($env:COMPUTERNAME)  TestOnce=$TestOnce NoShutdown=$NoShutdown ########"
Wait-Tailscale
Wait-Ollama | Out-Null
# Queue-Ordner sicherstellen
Ax "mkdir -p '$PendingDir' '$DoneDir'" | Out-Null

# --- WATCH-MODUS: dauerhaftes Pollen (fuer "space ist an / User zockt"), NIE Shutdown ---
if ($Watch) {
  Log "Watch-Modus aktiv: dauerhaftes Pollen alle ${PollSeconds}s, KEIN Shutdown. (Strg+C / Task beenden zum Stoppen)"
  while ($true) {
    $list = @(Ax "ls -1 $PendingDir/ 2>/dev/null" | Where-Object { $_ -match '\.json$' })
    if ($list.Count -gt 0) {
      Log "$($list.Count) Job(s) in der LLM-Queue"
      foreach ($f in $list) { if (Process-Job $f) { $jobsProcessed++ } }
    }
    Start-Sleep -Seconds $PollSeconds
  }
  return
}

$empty = 0
while ($true) {
  $list = @(Ax "ls -1 $PendingDir/ 2>/dev/null" | Where-Object { $_ -match '\.json$' })
  if ($list.Count -eq 0) {
    $empty++
    Log "Queue leer ($empty/$EmptyChecks)"
    if ($empty -ge $EmptyChecks) { break }
    Start-Sleep -Seconds $PollSeconds
    continue
  }
  $empty = 0
  Log "$($list.Count) Job(s) in der LLM-Queue"
  foreach ($f in $list) { if (Process-Job $f) { $jobsProcessed++ } }
}

Log "LLM-Queue abgearbeitet. ($jobsProcessed Job(s) in diesem Lauf)"

$SentinelNoShutdown = Join-Path (Split-Path $LogFile) "NO_SHUTDOWN"
if (-not $ShutdownWhenDone) { Log "ShutdownWhenDone=false -> bleibe an."; return }
if ($TestOnce)   { Log "TestOnce -> bleibe an."; return }
if ($NoShutdown) { Log "-NoShutdown gesetzt -> bleibe an."; return }
if (Test-Path $SentinelNoShutdown) { Log "Kill-Switch NO_SHUTDOWN vorhanden -> KEIN Shutdown (PC bleibt erreichbar)."; return }
if ($ShutdownOnlyIfUnattended -and (Test-InteractiveUser)) {
  Log "Interaktiver Benutzer angemeldet (zocken) -> KEIN Shutdown. Bleibe an."; return
}
if ($RequireJobToShutdown -and $jobsProcessed -le 0) {
  Log "Unbeaufsichtigt, aber kein Job verarbeitet -> KEIN Shutdown (evtl. Race). Bleibe an."; return
}
if (Test-CrackBusy) {
  Log "Crack-Pipeline arbeitet noch (hashcat laeuft / pending nicht leer) -> KEIN Shutdown. Ueberlasse das dem crack-agent."; return
}
if ($SuspendMode -eq "Sleep") {
  Log "Unbeaufsichtigt + $jobsProcessed Job(s) erledigt -> S3-Schlaf in $ShutdownDelaySec s (WoL-sicher)."
  Suspend-System -DelaySec $ShutdownDelaySec
} else {
  Log "Unbeaufsichtigt + $jobsProcessed Job(s) erledigt -> Shutdown in $ShutdownDelaySec s (Abbruch: shutdown /a)"
  & shutdown /s /t $ShutdownDelaySec /c "Jarvis LLM-Agent: $jobsProcessed Job(s) fertig, PC faehrt herunter. Abbruch: shutdown /a"
}

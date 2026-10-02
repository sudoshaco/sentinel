# 🛡️ Sentinel

Self-hosted homelab command center — local-first AI + defensive security, with **Jarvis** (a voice assistant) at its core. Runs on my own gear, shared so others can build on it.

> Defensive, own-lab use only.

## `pc-agent/` — Jarvis desktop cockpit (Windows)

Opens as a native app window (no browser tab): a voice assistant + a live security dashboard. What it does:

- **Voice assistant** — talk or type; an animated network orb reacts (idle · listening · thinking · speaking). **GPU-aware routing:** logged in → Claude Code (keeps the GPU free for gaming), headless → local **Ollama**. *Agent mode* plans ops and runs them only after you confirm in a visible terminal (human-in-the-loop).
- **Wazuh SIEM** — 24 h alerts (total / important ≥L7 / critical ≥L10), level breakdown, latest hits — plus a Claude triage that filters false positives.
- **Vulnerabilities** — CVE findings by severity + top CVEs (Wazuh vulnerability detection).
- **Agents** — status of every Wazuh agent (active / offline).
- **HackTheBox** — your rank, next box, and skill gaps.
- **Security news & CVEs** — heise Security + CISA KEV.
- **PC health** — CPU / RAM / disk / GPU.
- **Wellness** — water · meditation · sport.

Run `Jarvis.bat` to launch. Also ships a Wake-on-LAN pull-agent and voice-note intake.

## `phone-app/` — Jarvis Companion (Flutter / Android)

Receives Gotify push notifications and **reads them aloud** (TTS), push-to-talk voice notes, calendar tab. Grab **`jarvis-companion.apk`** and **sideload** it (allow "install unknown apps"). Tokens are entered in-app — nothing hardcoded.

---
*Defensive, own-lab only. Never commit secrets. WIP — forks welcome.*

@echo off
rem Jarvis Console starten (fensterlos) + im Browser oeffnen.
start "" "C:\Users\USER\AppData\Local\Programs\Python\Python312\pythonw.exe" "C:\Users\USER\jarvis-agent\jarvis-console.py"
timeout /t 2 >nul
start "" http://127.0.0.1:8900

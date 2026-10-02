import sys, json, urllib.request

inp = sys.argv[1]
outfile = sys.argv[2] if len(sys.argv) > 2 else None

if inp.lower().endswith('.txt'):
    transcript = open(inp, encoding='utf-8').read().strip()
else:
    import types, wave
    import numpy as np
    sys.modules['av'] = types.ModuleType('av')  # ffmpeg-DLL blockiert -> umgehen
    from faster_whisper import WhisperModel
    def load_wav(path):
        wf = wave.open(path, 'rb')
        sr, ch, sw = wf.getframerate(), wf.getnchannels(), wf.getsampwidth()
        raw = wf.readframes(wf.getnframes()); wf.close()
        if sw == 2:   a = np.frombuffer(raw, np.int16).astype(np.float32)/32768.0
        elif sw == 1: a = (np.frombuffer(raw, np.uint8).astype(np.float32)-128.0)/128.0
        else:         a = np.frombuffer(raw, np.int32).astype(np.float32)/2147483648.0
        if ch > 1: a = a.reshape(-1, ch).mean(axis=1)
        if sr != 16000:
            n = int(round(len(a)*16000/sr))
            a = np.interp(np.linspace(0,len(a),n,endpoint=False), np.arange(len(a)), a).astype(np.float32)
        return a
    model = WhisperModel("base", device="cpu", compute_type="int8")
    segs, _ = model.transcribe(load_wav(inp), language="de", beam_size=5)
    transcript = " ".join(s.text.strip() for s in segs).strip()

print("TRANSKRIPT: " + transcript)

SYS = ("Du wandelst eine deutsche Notiz in EINE knappe Kalenderzeile fuer eine Wochenplanung um. "
       "Format exakt: '- <Wochentag oder Datum> <Zeit falls genannt>: <kurze Beschreibung>'. "
       "Gib NUR die eine Zeile aus, keine Erklaerung.")
body = json.dumps({"model":"qwen2.5:7b","system":SYS,"prompt":transcript,"stream":False,
                   "options":{"temperature":0.2,"num_predict":60}}).encode()
req = urllib.request.Request("http://127.0.0.1:11434/api/generate", body, {"Content-Type":"application/json"})
line = json.loads(urllib.request.urlopen(req, timeout=120).read())["response"].strip().splitlines()[0].strip()
if not line.startswith("-"): line = "- " + line
print("WOCHE-ZEILE: " + line)
if outfile:
    open(outfile, "w", encoding="utf-8").write(line + "\n")

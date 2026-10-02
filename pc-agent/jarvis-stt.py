import sys, types, wave
import numpy as np
# PyAV (ffmpeg-DLL) ist per Windows-App-Control blockiert -> dummy-av injizieren,
# WAV selbst dekodieren und als numpy-Array an Whisper geben (kein ffmpeg noetig).
sys.modules['av'] = types.ModuleType('av')
from faster_whisper import WhisperModel

def load_wav(path):
    wf = wave.open(path, 'rb')
    sr, ch, sw = wf.getframerate(), wf.getnchannels(), wf.getsampwidth()
    raw = wf.readframes(wf.getnframes()); wf.close()
    if sw == 2:
        a = np.frombuffer(raw, np.int16).astype(np.float32) / 32768.0
    elif sw == 1:
        a = (np.frombuffer(raw, np.uint8).astype(np.float32) - 128.0) / 128.0
    else:
        a = np.frombuffer(raw, np.int32).astype(np.float32) / 2147483648.0
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    if sr != 16000:
        n = int(round(len(a) * 16000 / sr))
        a = np.interp(np.linspace(0, len(a), n, endpoint=False),
                      np.arange(len(a)), a).astype(np.float32)
    return a

MODEL = sys.argv[2] if len(sys.argv) > 2 else "base"
audio = load_wav(sys.argv[1])
model = WhisperModel(MODEL, device="cpu", compute_type="int8")
segments, info = model.transcribe(audio, language="de", beam_size=5)
print(" ".join(s.text.strip() for s in segments).strip())

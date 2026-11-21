"""Translation engine for Church AI Translation.

This is the same pipeline as the original translator.py
(Whisper speech-to-text -> NLLB-200 translation -> Piper Spanish voice),
reorganised into a class so the desktop window can start, stop and
monitor it. The engine has no GUI code; it reports back through callbacks.
"""
import json
import math
import os
import queue
import shutil
import threading
import time
import urllib.request
import warnings
import logging

import numpy as np
import sounddevice as sd

from word_filter import WordFilter, normalize as normalize_key

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VENV_DIR = os.path.join(SCRIPT_DIR, "venv")
MODELS_DIR = os.path.join(VENV_DIR, "models")
HF_CACHE_DIR = os.path.join(MODELS_DIR, "huggingface")
TORCH_CACHE_DIR = os.path.join(MODELS_DIR, "torch")
WHISPER_CACHE_DIR = os.path.join(MODELS_DIR, "whisper")

# Must be set before the AI libraries are imported (they are imported lazily in load_models)
os.environ.setdefault("HF_HOME", HF_CACHE_DIR)
os.environ.setdefault("TORCH_HOME", TORCH_CACHE_DIR)

STT_MODEL_NAME = "base.en"
# NLLB-200 1.3B: noticeably more accurate than the 600M model (about 5.5 GB download).
# If it isn't downloaded and there's no internet, the engine falls back to the 600M model.
TRANSLATION_MODEL_NAME = "facebook/nllb-200-distilled-1.3B"
FALLBACK_TRANSLATION_MODEL = "facebook/nllb-200-distilled-600M"
TTS_VOICE = "es_MX-ald-medium"
VOICE_BASE_URL = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/es/es_MX/ald/medium"

SAMPLE_RATE = 16000          # microphone sample rate fed to Whisper
METER_BLOCK = 800            # 50 ms of audio per input callback -> smooth level meters
OUTPUT_RATE = 48000          # playback sample rate
PIPER_RATE = 22050           # Piper voice native rate
WHISPER_PROMPT = "Welcome to church. Scripture, Genesis, Matthew, Gospel, Hallelujah, Amen."


class EngineError(Exception):
    """An error with a plain-language message suitable for a volunteer."""


# ------------------------------------------------------------------
# Audio device helpers
# ------------------------------------------------------------------
def refresh_devices():
    """Re-scan audio hardware so newly plugged-in USB devices show up."""
    try:
        sd._terminate()
        sd._initialize()
    except Exception:
        pass


def list_devices(kind):
    """Return [(index, name)] for 'input' or 'output' devices."""
    key = "max_input_channels" if kind == "input" else "max_output_channels"
    out = []
    for idx, dev in enumerate(sd.query_devices()):
        if dev[key] > 0:
            out.append((idx, dev["name"]))
    return out


def find_device(name, kind):
    """Find a device index by name. Returns None if not plugged in."""
    if not name:
        return None
    for idx, dev_name in list_devices(kind):
        if dev_name == name:
            return idx
    return None


# ------------------------------------------------------------------
# Engine
# ------------------------------------------------------------------
class TranslatorEngine:
    def __init__(self, on_status=None, on_transcript=None, on_log=None):
        # on_status(state, message): state is loading/ready/listening/error
        # on_transcript(timestamp, english, spanish, latency_seconds)
        # on_log(text)
        self._on_status = on_status or (lambda s, m: None)
        self._on_transcript = on_transcript or (lambda *a: None)
        self._on_log = on_log or (lambda t: None)

        self.models_loaded = False
        self.listening = False

        # Swear-word filter (word_filter.txt). Applied to English and Spanish before
        # anything is spoken, shown or saved; also blocks words inside the translator.
        self.word_filter = WordFilter()
        self._bad_words_ids = None
        self.filtered_count = 0

        self._stream = None
        self._stop_event = threading.Event()
        self._audio_queue = queue.Queue()
        self._playback_queue = queue.Queue()
        self._buffer = []
        self._buffer_len = 0
        self._lock = threading.Lock()

        # Live meter values (read by the GUI ~20x per second)
        self.input_rms = 0.0
        self.input_peak = 0.0
        self.last_speech_time = 0.0
        self.last_clip_time = 0.0
        self.last_delay = 0.0
        self._play_start = 0.0
        self._play_env = None

        # Volume faders (dB). Input gain is applied before the meter and the translator;
        # output gain is applied to the Spanish voice as each phrase starts playing.
        self.input_gain_db = 0.0
        self.output_gain_db = 0.0
        self._input_gain = 1.0
        self._output_gain = 1.0
        self._auto_samples = []
        self._auto_until = 0.0

        # Audio dropout recovery (see audio_watchdog)
        self._input_name = self._output_name = ""
        self._last_audio_time = time.time()
        self._recovering = False
        self._last_recover_attempt = 0.0

        # Settings (set in start())
        self.block_size_seconds = 3.0
        self.silence_threshold = 0.003
        self.speech_speed = "normal"
        self.output_device = None

    # ---------------- logging helpers ----------------
    def _log(self, text):
        print(text, flush=True)
        self._on_log(text)

    def _status(self, state, message):
        self._log(f"[{state}] {message}")
        self._on_status(state, message)

    # ---------------- model loading ----------------
    def load_models(self):
        """Load all AI models. Slow (20-60s); call from a background thread."""
        try:
            self._load_models()
        except EngineError as e:
            self._status("error", str(e))
            return False
        except Exception as e:
            self._status("error", f"The translation models couldn't be loaded: {e}")
            return False
        self.models_loaded = True
        self._status("ready", "Ready. Press Start when the service begins.")
        return True

    def _load_models(self):
        warnings.filterwarnings("ignore", category=UserWarning, module="urllib3")
        warnings.filterwarnings("ignore", message=".*unauthenticated requests.*")
        warnings.filterwarnings("ignore", module="huggingface_hub")
        logging.getLogger("huggingface_hub").setLevel(logging.ERROR)

        for d in (MODELS_DIR, HF_CACHE_DIR, WHISPER_CACHE_DIR):
            os.makedirs(d, exist_ok=True)

        voice_path, voice_cfg_path = self._ensure_voice_files()

        self._status("loading", "Loading speech recognition (1 of 3)…")
        import torch
        from faster_whisper import WhisperModel

        self._device_type = "mps" if torch.backends.mps.is_available() else "cpu"
        self._stt = WhisperModel(
            STT_MODEL_NAME,
            device="cpu",
            compute_type="int8",
            cpu_threads=6,
            download_root=WHISPER_CACHE_DIR,
        )

        self._status("loading", "Loading translation model (2 of 3)…")
        self._load_translator(torch)
        self._target_lang_id = self._tokenizer.convert_tokens_to_ids("spa_Latn")
        self._bad_words_ids = self._build_bad_words_ids()

        self._status("loading", "Loading Spanish voice (3 of 3)…")
        from piper.voice import PiperVoice
        from piper.config import SynthesisConfig

        self._SynthesisConfig = SynthesisConfig
        self._voice = PiperVoice.load(voice_path, config_path=voice_cfg_path)
        for _ in self._voice.synthesize("listo"):  # warm up
            pass

        # Background workers live for the life of the app
        threading.Thread(target=self._playback_worker, daemon=True).start()
        threading.Thread(target=self._processing_worker, daemon=True).start()

    def _build_bad_words_ids(self):
        """Find every whole-word piece in the translator's vocabulary that the word filter
        blocks or replaces, so the model picks a different word instead of producing it."""
        wf = self.word_filter
        if not wf.loaded:
            self._log("[!] word_filter.txt not found; swear-word filter is OFF.")
            return None
        t0 = time.time()
        banned = []
        for piece, idx in self._tokenizer.get_vocab().items():
            if not piece.startswith("▁"):      # only pieces that start a word
                continue
            word = piece[1:]
            if len(word) < 3 or not word.isalpha():
                continue
            if wf.is_blocked(word) or normalize_key(word) in wf.replacements:
                banned.append([idx])
        self._log(f"[+] Word filter: {len(banned)} vocabulary pieces blocked in the translator "
                  f"({time.time() - t0:.1f}s)")
        return banned or None

    def _load_translator(self, torch):
        """Load NLLB 1.3B (downloading it once if needed); fall back to 600M when offline."""
        from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

        # Half precision on the Apple GPU: half the memory, faster, same translations in practice
        dtype = torch.float16 if self._device_type == "mps" else torch.float32

        def load(name, local_only):
            tok = AutoTokenizer.from_pretrained(
                name, src_lang="eng_Latn", cache_dir=HF_CACHE_DIR, local_files_only=local_only)
            model = AutoModelForSeq2SeqLM.from_pretrained(
                name, cache_dir=HF_CACHE_DIR, local_files_only=local_only, dtype=dtype)
            return tok, model.to(self._device_type).eval()

        attempts = [
            (TRANSLATION_MODEL_NAME, True, None),
            (TRANSLATION_MODEL_NAME, False,
             "Downloading the larger translation model (about 5.5 GB, first run only)…"),
            (FALLBACK_TRANSLATION_MODEL, True, None),
            (FALLBACK_TRANSLATION_MODEL, False,
             "Downloading translation model (about 2.4 GB, first run only)…"),
        ]
        last_error = None
        for name, local_only, message in attempts:
            if message:
                self._status("loading", message)
            try:
                self._tokenizer, self._translator = load(name, local_only)
                self.translation_model_name = name
                if name != TRANSLATION_MODEL_NAME:
                    self._log(f"[!] Using the smaller translation model ({name}); "
                              "connect to the internet once to download the larger one.")
                else:
                    self._log(f"[+] Translation model: {name}")
                return
            except Exception as e:
                last_error = e
        raise EngineError(f"The translation model couldn't be loaded or downloaded. ({last_error})")

    def _ensure_voice_files(self):
        voice = os.path.join(MODELS_DIR, f"{TTS_VOICE}.onnx")
        cfg = os.path.join(MODELS_DIR, f"{TTS_VOICE}.onnx.json")

        # Move legacy copies from the project folder or venv root
        for src_dir in (SCRIPT_DIR, VENV_DIR):
            for fname, dest in ((f"{TTS_VOICE}.onnx", voice), (f"{TTS_VOICE}.onnx.json", cfg)):
                src = os.path.join(src_dir, fname)
                if os.path.exists(src) and not os.path.exists(dest):
                    try:
                        shutil.move(src, dest)
                    except Exception:
                        pass

        for path, fname in ((voice, f"{TTS_VOICE}.onnx"), (cfg, f"{TTS_VOICE}.onnx.json")):
            if not os.path.exists(path):
                self._status("loading", f"Downloading Spanish voice ({fname})…")
                try:
                    urllib.request.urlretrieve(f"{VOICE_BASE_URL}/{fname}", path)
                except Exception as e:
                    raise EngineError(
                        "The Spanish voice files are missing and couldn't be downloaded. "
                        f"Check the internet connection, or run setup again. ({e})")

        # Normalise phoneme_type for Piper enum compatibility
        try:
            with open(cfg, "r", encoding="utf-8") as f:
                data = json.load(f)
            if data.get("phoneme_type") in ("PhonemeType.ESPEAK", "ESPEAK"):
                data["phoneme_type"] = "espeak"
                with open(cfg, "w", encoding="utf-8") as f:
                    json.dump(data, f, indent=2)
        except Exception:
            pass
        return voice, cfg

    # ---------------- start / stop ----------------
    def start(self, input_name, output_name, block_size_seconds=3.0,
              silence_threshold=0.003, speech_speed="normal"):
        if not self.models_loaded:
            raise EngineError("The translation models are still loading. Wait for Ready.")
        if self.listening:
            return

        in_idx = find_device(input_name, "input")
        out_idx = find_device(output_name, "output")
        if in_idx is None:
            raise EngineError(
                f"The microphone “{input_name or 'none selected'}” isn't connected. "
                "Check the USB cable, then pick it in the Microphone list.")
        if out_idx is None:
            raise EngineError(
                f"The speaker output “{output_name or 'none selected'}” isn't connected. "
                "Check the cable, then pick it in the Speakers list.")

        self.block_size_seconds = block_size_seconds
        self.silence_threshold = silence_threshold
        self.speech_speed = speech_speed
        self.output_device = out_idx

        self._clear_queues()
        with self._lock:
            self._buffer, self._buffer_len = [], 0
        self._stop_event.clear()

        try:
            self._stream = sd.InputStream(
                device=in_idx, channels=1, samplerate=SAMPLE_RATE,
                blocksize=METER_BLOCK, callback=self._audio_callback)
            self._stream.start()
        except Exception as e:
            self._stream = None
            raise EngineError(f"Couldn't open the microphone “{input_name}”. ({e})")

        self.listening = True
        self._input_name, self._output_name = input_name, output_name
        self._last_audio_time = time.time()
        self._recovering = False
        self._last_recover_attempt = 0.0
        self._status("listening", f"Listening on {input_name}")

    # ---------------- audio dropout recovery ----------------
    def seconds_since_audio(self):
        return time.time() - self._last_audio_time

    def audio_watchdog(self):
        """Call about once a second while listening. A microphone sends audio continuously
        (even silence), so none for 3 seconds means the device dropped out (e.g. the USB
        interface was unplugged). Reopens the audio devices every 2 seconds until audio flows.
        Returns a message for the volunteer when something changed, else None."""
        if not self.listening:
            return None
        silent_for = self.seconds_since_audio()
        if silent_for > 3:
            message = None
            if not self._recovering:
                self._recovering = True
                message = "The microphone stopped sending sound. Reconnecting…"
                self._log("[!] No audio from the microphone for 3 s; reconnecting")
            if time.time() - self._last_recover_attempt >= 2:
                self._last_recover_attempt = time.time()
                self._reopen_audio()
            return message
        if self._recovering and silent_for < 1:
            self._recovering = False
            self._log("[+] Microphone audio is flowing again")
            return "The microphone reconnected. Translation continues."
        return None

    def _reopen_audio(self):
        """Close the mic stream, re-scan devices (so a replugged USB interface is found again,
        possibly under a new number), and reopen the mic and speaker by name."""
        if self._stream is not None:
            try:
                self._stream.abort()
                self._stream.close()
            except Exception:
                pass
            self._stream = None
        try:
            sd.stop()
        except Exception:
            pass
        refresh_devices()
        in_idx = find_device(self._input_name, "input")
        out_idx = find_device(self._output_name, "output")
        if out_idx is not None:
            self.output_device = out_idx
        if in_idx is None:
            self._log("[!] Microphone still not connected; will try again")
            return
        try:
            self._stream = sd.InputStream(
                device=in_idx, channels=1, samplerate=SAMPLE_RATE,
                blocksize=METER_BLOCK, callback=self._audio_callback)
            self._stream.start()
            self._log(f"[+] Reopened microphone {self._input_name}")
        except Exception as e:
            self._stream = None
            self._log(f"[!] Couldn't reopen the microphone yet: {e}")

    def simulate_dropout(self):
        """Testing: silently stop the microphone, as a failing USB interface would."""
        if self._stream is not None:
            self._stream.abort()

    def stop(self):
        self._stop_event.set()
        if self._stream is not None:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception:
                pass
            self._stream = None
        self._clear_queues()
        try:
            sd.stop()
        except Exception:
            pass
        self.input_rms = self.input_peak = 0.0
        if self.listening:
            self.listening = False
            self._status("ready", "Stopped. Press Start to begin again.")

    def _clear_queues(self):
        for q in (self._audio_queue, self._playback_queue):
            while True:
                try:
                    q.get_nowait()
                except queue.Empty:
                    break

    def test_speakers(self, output_name):
        """Speak a short Spanish phrase through the chosen output."""
        if not self.models_loaded:
            raise EngineError("Wait for the models to finish loading first.")
        out_idx = find_device(output_name, "output")
        if out_idx is None:
            raise EngineError(f"The speaker output “{output_name}” isn't connected.")
        if not self.listening:
            self.output_device = out_idx
        self._synthesize("Prueba de sonido. Uno, dos, tres.")

    # ---------------- live stats for the GUI ----------------
    def output_rms(self):
        env, start = self._play_env, self._play_start
        if env is None:
            return 0.0
        i = int((time.time() - start) / 0.05)
        if 0 <= i < len(env):
            return float(env[i])
        return 0.0

    def queue_depth(self):
        return self._audio_queue.qsize() + self._playback_queue.qsize()

    # ---------------- audio pipeline ----------------
    # ---------------- volume (gain) controls ----------------
    INPUT_GAIN_RANGE = (-12.0, 24.0)    # dB
    OUTPUT_GAIN_RANGE = (-24.0, 12.0)   # dB
    AUTO_TARGET_RMS = 0.1               # about -20 dBFS: a healthy speech level
    AUTO_SECONDS = 10.0

    def set_input_gain_db(self, db):
        lo, hi = self.INPUT_GAIN_RANGE
        self.input_gain_db = max(lo, min(hi, float(db)))
        self._input_gain = 10 ** (self.input_gain_db / 20)

    def set_output_gain_db(self, db):
        lo, hi = self.OUTPUT_GAIN_RANGE
        self.output_gain_db = max(lo, min(hi, float(db)))
        self._output_gain = 10 ** (self.output_gain_db / 20)

    def start_auto_level(self):
        """Measure the microphone for AUTO_SECONDS while listening; see auto_level_result()."""
        with self._lock:
            self._auto_samples = []
            self._auto_until = time.time() + self.AUTO_SECONDS

    @property
    def auto_level_running(self):
        return self._auto_until > time.time()

    def auto_level_result(self):
        """Suggested input gain (dB) from the last measurement, or None if no speech was heard."""
        with self._lock:
            samples = sorted(self._auto_samples)
        if len(samples) < 20:          # under ~1 s of speech
            return None
        speech = samples[int(len(samples) * 0.9)]   # 90th percentile of speech loudness
        if speech <= 0:
            return None
        db = 20 * math.log10(self.AUTO_TARGET_RMS / speech)
        lo, hi = self.INPUT_GAIN_RANGE
        return round(max(lo, min(hi, db)))

    def _audio_callback(self, indata, frames, time_info, status):
        self._last_audio_time = time.time()
        raw = indata[:, 0]
        if self._auto_until > time.time():
            # Auto level measures the microphone before any gain is applied
            raw_rms = float(np.sqrt(np.mean(raw ** 2)))
            if raw_rms >= self.silence_threshold / max(self._input_gain, 1e-6) * 0.5:
                with self._lock:
                    self._auto_samples.append(raw_rms)
        mono = raw if self._input_gain == 1.0 else np.clip(raw * self._input_gain, -1.0, 1.0)
        self.input_rms = float(np.sqrt(np.mean(mono ** 2)))
        self.input_peak = float(np.max(np.abs(mono))) if len(mono) else 0.0
        now = time.time()
        if self.input_rms >= self.silence_threshold:
            self.last_speech_time = now
        if self.input_peak >= 0.99:
            self.last_clip_time = now

        chunk_samples = int(SAMPLE_RATE * self.block_size_seconds)
        with self._lock:
            self._buffer.append(mono.copy())
            self._buffer_len += len(mono)
            if self._buffer_len >= chunk_samples:
                block = np.concatenate(self._buffer)
                self._buffer, self._buffer_len = [], 0
                self._audio_queue.put((block, now))

    def _processing_worker(self):
        while True:
            block, captured_at = self._audio_queue.get()
            if self._stop_event.is_set():
                continue
            audio = block.astype(np.float32)

            # Skip dead silence to save CPU
            if np.sqrt(np.mean(audio ** 2)) < self.silence_threshold:
                continue

            # Catch-up guard: if we've fallen behind, drop stale audio
            if self._audio_queue.qsize() > 3:
                while self._audio_queue.qsize() > 1:
                    try:
                        self._audio_queue.get_nowait()
                    except queue.Empty:
                        break
                self._log("[!] Fell behind; skipped some audio to stay live.")

            try:
                segments, _ = self._stt.transcribe(
                    audio, beam_size=1, language="en",
                    initial_prompt=WHISPER_PROMPT, vad_filter=True,
                    vad_parameters=dict(min_silence_duration_ms=300))
                text_en = " ".join(s.text for s in segments).strip()
                if not text_en or self._stop_event.is_set():
                    continue

                # Word filter, English side: a misheard swear is shown as ••• and
                # left out of what gets translated.
                shown_en, n_en = self.word_filter.clean(text_en, mask="•••")
                to_translate, _ = self.word_filter.clean(text_en, mask="")
                if not to_translate:
                    self._note_filtered(n_en)
                    continue

                text_es = self._translate(to_translate)

                # Word filter, Spanish side: swap risky regional words, drop blocked ones,
                # before anything is spoken, captioned or saved.
                text_es, n_es = self.word_filter.clean(text_es, mask="")
                self._note_filtered(n_en + n_es)
                if text_es:
                    self._synthesize(text_es)
                latency = time.time() - captured_at
                self.last_delay = latency
                self._log(f"[EN]: {shown_en}\n[ES]: {text_es}")
                self._on_transcript(time.strftime("%H:%M:%S"), shown_en, text_es or "(filtered)", latency)
            except Exception as e:
                self._log(f"[!] Translation error: {e}")

    def _note_filtered(self, count):
        if count:
            self.filtered_count += count
            # The words themselves are never logged
            self._log(f"[filter] Changed or removed {count} word(s) in this phrase.")

    def _translate(self, text):
        inputs = self._tokenizer(text, return_tensors="pt", padding=True).to(self._device_type)
        tokens = self._translator.generate(
            **inputs, forced_bos_token_id=self._target_lang_id,
            max_length=128, num_beams=1,
            bad_words_ids=self._bad_words_ids)
        return self._tokenizer.batch_decode(tokens, skip_special_tokens=True)[0]

    def _synthesize(self, text_es):
        if not text_es or not text_es.strip():
            return
        backlog = self._playback_queue.qsize()
        # Normal: 1.1x speed. Fast setting or a backlog: 1.25x to catch up.
        if backlog >= 2 or self.speech_speed == "fast":
            cfg = self._SynthesisConfig(length_scale=0.80)
        else:
            cfg = self._SynthesisConfig(length_scale=0.90)
        try:
            chunks = list(self._voice.synthesize(text_es, syn_config=cfg))
            raw = b"".join(c.audio_int16_bytes for c in chunks)
            pcm = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
            if len(pcm) == 0:
                return
            target_len = int(len(pcm) / PIPER_RATE * OUTPUT_RATE)
            resampled = np.interp(
                np.linspace(0, len(pcm), target_len, endpoint=False),
                np.arange(len(pcm)), pcm).astype(np.float32)
            # Loudness envelope in 50 ms steps for the output meter
            step = int(OUTPUT_RATE * 0.05)
            n = len(resampled) // step
            env = np.sqrt(np.mean(resampled[: n * step].reshape(n, step) ** 2, axis=1)) if n else None
            stereo = np.column_stack((resampled, resampled))
            self._playback_queue.put((stereo, env))
        except Exception as e:
            self._log(f"[!] Spanish voice error: {e}")

    def _playback_worker(self):
        while True:
            stereo, env = self._playback_queue.get()
            try:
                gain = self._output_gain
                if gain != 1.0:
                    stereo = np.clip(stereo * gain, -1.0, 1.0)
                    if env is not None:
                        env = np.minimum(env * gain, 1.0)
                self._play_env, self._play_start = env, time.time()
                sd.play(stereo, samplerate=OUTPUT_RATE, device=self.output_device)
                sd.wait()
            except Exception as e:
                self._log(f"[!] Speaker output error: {e}")
            finally:
                self._play_env = None

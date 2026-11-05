import configparser
import json
import os
import queue
import shutil
import signal
import sys
import threading
import urllib.request
import warnings

# Define directories and cache locations inside venv
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VENV_DIR = os.path.join(SCRIPT_DIR, "venv")
MODELS_DIR = os.path.join(VENV_DIR, "models")
HF_CACHE_DIR = os.path.join(MODELS_DIR, "huggingface")
TORCH_CACHE_DIR = os.path.join(MODELS_DIR, "torch")
WHISPER_CACHE_DIR = os.path.join(MODELS_DIR, "whisper")

# Set cache environment variables before importing AI packages
os.environ.setdefault("HF_HOME", HF_CACHE_DIR)
os.environ.setdefault("TORCH_HOME", TORCH_CACHE_DIR)

import numpy as np
import sounddevice as sd
import torch
from faster_whisper import WhisperModel
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer
from piper.voice import PiperVoice
from piper.config import SynthesisConfig

# Suppress harmless warnings from urllib3 and Hugging Face Hub
warnings.filterwarnings("ignore", category=UserWarning, module="urllib3")
warnings.filterwarnings("ignore", message=".*unauthenticated requests.*")
warnings.filterwarnings("ignore", module="huggingface_hub")

import logging
logging.getLogger("huggingface_hub").setLevel(logging.ERROR)

# Ensure unbuffered real-time stdout streaming
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(line_buffering=True)

# Graceful termination on SIGTERM from GUI or terminal
def sigterm_handler(signum, frame):
    print("\n[+] Stopping translation system...", flush=True)
    sys.exit(0)

signal.signal(signal.SIGTERM, sigterm_handler)

USER_CONFIG = os.path.expanduser("~/ChurchAI/churchaitranslate.conf")
LOCAL_CONFIG = os.path.join(SCRIPT_DIR, "churchaitranslate.conf")

# ==========================================
# LOAD CONFIGURATION FILE
# ==========================================
if os.path.exists(USER_CONFIG):
    CONFIG_FILE = USER_CONFIG
elif os.path.exists(LOCAL_CONFIG):
    CONFIG_FILE = LOCAL_CONFIG
else:
    print(f"[!] Config file not found at: {USER_CONFIG}")
    print("[!] Please run 'Configure Audio' first.")
    sys.exit(1)

config = configparser.ConfigParser()
config.read(CONFIG_FILE)

INPUT_DEVICE_ID = int(config.get("AUDIO", "input_device_id"))
INPUT_NAME = config.get("AUDIO", "input_device_name")
OUTPUT_DEVICE_ID = int(config.get("AUDIO", "output_device_id"))
OUTPUT_NAME = config.get("AUDIO", "output_device_name")

SAMPLE_RATE = int(config.get("AUDIO", "sample_rate", fallback="16000"))
BLOCK_SIZE_SEC = int(config.get("AUDIO", "block_size_seconds", fallback="3"))
BLOCK_SIZE = SAMPLE_RATE * BLOCK_SIZE_SEC

# Real-time optimized models (<0.7s total latency)
STT_MODEL_NAME = "base.en"
TRANSLATION_MODEL_NAME = "facebook/nllb-200-distilled-600M"
TTS_VOICE = "es_MX-ald-medium"

# Ensure venv models directories exist
os.makedirs(MODELS_DIR, exist_ok=True)
os.makedirs(HF_CACHE_DIR, exist_ok=True)
os.makedirs(WHISPER_CACHE_DIR, exist_ok=True)

# Resolve absolute paths to local ONNX voice and config inside venv/models
VOICE_FILE_PATH = os.path.join(MODELS_DIR, f"{TTS_VOICE}.onnx")
CONFIG_FILE_PATH = os.path.join(MODELS_DIR, f"{TTS_VOICE}.onnx.json")

# Clean up / relocate any legacy voice model files from project root to keep root clean
for fname, dest_path in [
    (f"{TTS_VOICE}.onnx", VOICE_FILE_PATH),
    (f"{TTS_VOICE}.onnx.json", CONFIG_FILE_PATH),
]:
    legacy_file = os.path.join(SCRIPT_DIR, fname)
    if os.path.exists(legacy_file) and not os.path.exists(dest_path):
        try:
            shutil.move(legacy_file, dest_path)
            print(f"[+] Relocated {fname} from project root to {MODELS_DIR}", flush=True)
        except Exception as e:
            print(f"[!] Warning: Could not move {fname} to venv/models: {e}", flush=True)

# Fallback: check directly in venv root if placed there
if not os.path.exists(VOICE_FILE_PATH) and os.path.exists(os.path.join(VENV_DIR, f"{TTS_VOICE}.onnx")):
    VOICE_FILE_PATH = os.path.join(VENV_DIR, f"{TTS_VOICE}.onnx")
    CONFIG_FILE_PATH = os.path.join(VENV_DIR, f"{TTS_VOICE}.onnx.json")

# If voice assets are missing, attempt automatic download to venv/models
if not os.path.exists(VOICE_FILE_PATH) or not os.path.exists(CONFIG_FILE_PATH):
    print(f"[+] Downloading missing Piper TTS voice assets to {MODELS_DIR}...", flush=True)
    base_voice_url = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/es/es_MX/ald/medium"
    try:
        if not os.path.exists(VOICE_FILE_PATH):
            print(f"[+] Downloading {TTS_VOICE}.onnx to {MODELS_DIR}...", flush=True)
            urllib.request.urlretrieve(f"{base_voice_url}/{TTS_VOICE}.onnx", VOICE_FILE_PATH)
        if not os.path.exists(CONFIG_FILE_PATH):
            print(f"[+] Downloading {TTS_VOICE}.onnx.json to {MODELS_DIR}...", flush=True)
            urllib.request.urlretrieve(f"{base_voice_url}/{TTS_VOICE}.onnx.json", CONFIG_FILE_PATH)
    except Exception as e:
        print(f"[!] Warning: Auto-download of voice assets failed: {e}", flush=True)

if not os.path.exists(VOICE_FILE_PATH):
    print(f"[!] ERROR: TTS voice model missing: {VOICE_FILE_PATH}")
    print("[!] Please run setup_mac.sh to download required assets.")
    sys.exit(1)

if not os.path.exists(CONFIG_FILE_PATH):
    print(f"[!] ERROR: TTS voice config missing: {CONFIG_FILE_PATH}")
    print("[!] Please run setup_mac.sh to download required assets.")
    sys.exit(1)

# ==========================================
# SANITIZE PIPER JSON CONFIG FILE
# ==========================================
try:
    with open(CONFIG_FILE_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    # Normalize phoneme_type string for Piper Enum compatibility
    if "phoneme_type" in cfg and cfg["phoneme_type"] in ["PhonemeType.ESPEAK", "ESPEAK", "espeak"]:
        cfg["phoneme_type"] = "espeak"
        with open(CONFIG_FILE_PATH, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
except Exception as e:
    print(f"[!] Warning: Failed to check/sanitize Piper JSON config: {e}")

# ==========================================
# INITIALIZE HARDWARE & MODELS
# ==========================================
device_type = "mps" if torch.backends.mps.is_available() else "cpu"

print("==========================================", flush=True)
print("  HIGH-SPEED CHURCH AI LIVE TRANSLATOR", flush=True)
print("==========================================", flush=True)
print(f"STT Model:     [{STT_MODEL_NAME} (Fast Real-Time)]", flush=True)
print(f"Translator:    [{TRANSLATION_MODEL_NAME}]", flush=True)
print(f"TTS Accent:    [Latin American Spanish ({TTS_VOICE})]", flush=True)
print(f"TTS Mode:      [In-Memory In-Process Synthesis]", flush=True)
print(f"Acceleration:  [{device_type.upper()}]", flush=True)
print("==========================================", flush=True)

# 1. Load Whisper Speech-to-Text
print("\n[+] Loading Speech-to-Text (Whisper Base Real-Time)...", flush=True)
print("    (Downloading model assets if first run ~140MB)...", flush=True)
stt_model = WhisperModel(
    STT_MODEL_NAME,
    device="cpu",
    compute_type="int8",
    cpu_threads=6,
    download_root=WHISPER_CACHE_DIR,
)
print("[✓] Speech-to-Text engine loaded successfully.", flush=True)

# 2. Load NLLB-200 Translation Model
print(f"\n[+] Loading NLLB-200 Translation Model on {device_type.upper()}...", flush=True)
try:
    tokenizer = AutoTokenizer.from_pretrained(
        TRANSLATION_MODEL_NAME,
        src_lang="eng_Latn",
        cache_dir=HF_CACHE_DIR,
        local_files_only=True,
    )
    translation_model = AutoModelForSeq2SeqLM.from_pretrained(
        TRANSLATION_MODEL_NAME,
        cache_dir=HF_CACHE_DIR,
        local_files_only=True,
    ).to(device_type)
except Exception:
    print("    (Downloading NLLB-200 model weights into venv/models ~2.4GB - please wait)...", flush=True)
    tokenizer = AutoTokenizer.from_pretrained(
        TRANSLATION_MODEL_NAME,
        src_lang="eng_Latn",
        cache_dir=HF_CACHE_DIR,
    )
    translation_model = AutoModelForSeq2SeqLM.from_pretrained(
        TRANSLATION_MODEL_NAME,
        cache_dir=HF_CACHE_DIR,
    ).to(device_type)
print("[✓] NLLB-200 Translation model loaded successfully.", flush=True)

TARGET_LANG_ID = tokenizer.convert_tokens_to_ids("spa_Latn")

# 3. Preload Piper TTS into Memory (eliminates 1.1s subprocess spawn latency)
print(f"\n[+] Preloading In-Memory Piper TTS Voice ({TTS_VOICE})...", flush=True)
piper_voice = PiperVoice.load(VOICE_FILE_PATH, config_path=CONFIG_FILE_PATH)
# Warm up ONNX runtime
for _ in piper_voice.synthesize("listo"):
    pass
print("[✓] Piper TTS voice engine warmed up and ready.", flush=True)


def translate_text(text):
    """Translates English text to Spanish using Meta's NLLB-200 model."""
    inputs = tokenizer(text, return_tensors="pt", padding=True).to(device_type)
    translated_tokens = translation_model.generate(
        **inputs,
        forced_bos_token_id=TARGET_LANG_ID,
        max_length=128,
        num_beams=1,
    )
    return tokenizer.batch_decode(translated_tokens, skip_special_tokens=True)[0]


print("\n[✓] High-speed real-time models loaded successfully!\n", flush=True)

# ==========================================
# ASYNCHRONOUS PIPELINES & QUEUES
# ==========================================
audio_queue = queue.Queue()
playback_queue = queue.Queue()


def audio_callback(indata, frames, time, status):
    if status:
        print(f"Audio Warning: {status}", file=sys.stderr)
    audio_queue.put(indata.copy())


def audio_playback_worker():
    """
    Dedicated audio output thread. Plays Spanish audio continuously without blocking
    the Speech-to-Text or Translation pipeline.
    """
    while True:
        try:
            stereo_audio = playback_queue.get()
            if stereo_audio is None:
                break
            sd.play(stereo_audio, samplerate=48000, device=OUTPUT_DEVICE_ID)
            sd.wait()
            playback_queue.task_done()
        except Exception as e:
            print(f"[!] Audio Playback Error: {e}", file=sys.stderr, flush=True)


# Start background audio playback thread
playback_thread = threading.Thread(target=audio_playback_worker, daemon=True)
playback_thread.start()


def synthesize_and_enqueue_tts(text_es, backlog_count=0):
    """
    Synthesizes Spanish audio directly in-memory via Piper ONNX and sends to playback queue.
    Takes ~0.12s instead of 1.1s subprocess spawn.
    """
    if not text_es or not text_es.strip():
        return

    try:
        # Dynamic Speech Rate:
        # Normal Spanish cadence: 1.1x speed (length_scale=0.90) to match English flow
        # Backlog catch-up: 1.25x speed (length_scale=0.80) if multiple sentences are queued
        if backlog_count >= 2:
            syn_cfg = SynthesisConfig(length_scale=0.80)
        else:
            syn_cfg = SynthesisConfig(length_scale=0.90)

        chunks = list(piper_voice.synthesize(text_es, syn_config=syn_cfg))
        if not chunks:
            return

        raw_wav = b"".join(c.audio_int16_bytes for c in chunks)
        audio_int16 = np.frombuffer(raw_wav, dtype=np.int16)
        if len(audio_int16) == 0:
            return

        audio_float32 = audio_int16.astype(np.float32) / 32768.0

        # Resample 22.05kHz to 48kHz stereo for Focusrite / Mac output
        target_rate = 48000
        duration = len(audio_float32) / 22050
        target_length = int(duration * target_rate)

        resampled_audio = np.interp(
            np.linspace(0, len(audio_float32), target_length, endpoint=False),
            np.arange(len(audio_float32)),
            audio_float32,
        )

        stereo_audio = np.column_stack((resampled_audio, resampled_audio))
        playback_queue.put(stereo_audio)

    except Exception as e:
        print(f"[!] In-Memory TTS Synthesis Error: {e}", file=sys.stderr, flush=True)


def process_translation():
    """
    Continuous translation loop:
    1. Speech-to-Text (~0.33s)
    2. NLLB Translation (~0.60s)
    3. In-Memory TTS (~0.12s)
    Never blocked by audio playback.
    """
    while True:
        audio_data = audio_queue.get()
        audio_np = audio_data.flatten().astype(np.float32)

        # Quick Energy Gate (skip processing dead silence to save CPU)
        rms = np.sqrt(np.mean(audio_np ** 2))
        if rms < 0.003:
            audio_queue.task_done()
            continue

        # Real-time Catch-up Guard:
        # If queue has accumulated > 3 chunks (e.g. speaking during model load),
        # drop stale audio to stay live with current speech
        if audio_queue.qsize() > 3:
            while audio_queue.qsize() > 1:
                try:
                    audio_queue.get_nowait()
                    audio_queue.task_done()
                except queue.Empty:
                    break

        # 1. Fast Speech-to-Text
        segments, _ = stt_model.transcribe(
            audio_np,
            beam_size=1,
            language="en",
            initial_prompt="Welcome to church. Scripture, Genesis, Matthew, Gospel, Hallelujah, Amen.",
            vad_filter=True,
            vad_parameters=dict(min_silence_duration_ms=300),
        )

        text_en = " ".join([segment.text for segment in segments]).strip()

        if text_en:
            print(f"[EN]: {text_en}", flush=True)

            # 2. English -> Spanish Translation
            text_es = translate_text(text_en)
            print(f"[ES]: {text_es}\n", flush=True)

            # 3. Asynchronous Text-to-Speech Output (Non-blocking)
            synthesize_and_enqueue_tts(text_es, backlog_count=playback_queue.qsize())

        audio_queue.task_done()


# Start background translation thread
thread = threading.Thread(target=process_translation, daemon=True)
thread.start()

# Open incoming audio stream
try:
    with sd.InputStream(
        device=INPUT_DEVICE_ID,
        channels=1,
        samplerate=SAMPLE_RATE,
        blocksize=BLOCK_SIZE,
        callback=audio_callback,
    ):
        print("\n" + "=" * 60, flush=True)
        print("  🟢 CHURCH AI TRANSLATOR IS ONLINE & ACTIVELY LISTENING", flush=True)
        print("=" * 60, flush=True)
        print(f"  [*] Input Device:   [{INPUT_DEVICE_ID}] {INPUT_NAME}", flush=True)
        print(f"  [*] Output Device:  [{OUTPUT_DEVICE_ID}] {OUTPUT_NAME}", flush=True)
        print("  [*] Status:         ACTIVE — Speak into your microphone now!", flush=True)
        print("=" * 60 + "\n", flush=True)

        # Trigger macOS native notification & audio chime
        try:
            os.system(
                "osascript -e 'display notification \"Live speech translation is active and listening!\" with title \"Church AI Translation\" subtitle \"System Ready\" sound name \"Glass\"' 2>/dev/null"
            )
        except Exception:
            pass

        while True:
            sd.sleep(1000)
except KeyboardInterrupt:
    print("\n[+] Stopping translation system...", flush=True)

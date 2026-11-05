"""Settings storage for Church AI Translation.

Settings live in ~/ChurchAI/churchaitranslate.conf (same file the old
configure_audio.py wrote), so existing installs keep their device choices.
Devices are remembered by NAME, because macOS device ID numbers can change
when USB devices are plugged in a different order.
"""
import configparser
import os
from dataclasses import dataclass, asdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
USER_DIR = os.path.expanduser("~/ChurchAI")
USER_CONFIG = os.path.join(USER_DIR, "churchaitranslate.conf")
LOCAL_CONFIG = os.path.join(SCRIPT_DIR, "churchaitranslate.conf")
TRANSCRIPTS_DIR = os.path.join(USER_DIR, "Transcripts")
LOG_DIR = os.path.join(USER_DIR, "logs")


@dataclass
class Settings:
    input_device_name: str = ""
    output_device_name: str = ""
    # Seconds of audio collected before each translation (shorter = faster but choppier)
    block_size_seconds: float = 3.0
    # Below this loudness (RMS) audio is treated as silence and skipped
    silence_threshold: float = 0.003
    # "normal" or "fast" Spanish speech
    speech_speed: str = "normal"
    # Start listening automatically as soon as models finish loading
    auto_start: bool = False
    # Caption window font size in points
    caption_font_size: int = 54


def load_settings() -> Settings:
    s = Settings()
    path = USER_CONFIG if os.path.exists(USER_CONFIG) else LOCAL_CONFIG
    if not os.path.exists(path):
        return s
    cfg = configparser.ConfigParser()
    try:
        cfg.read(path)
    except configparser.Error:
        return s
    a = cfg["AUDIO"] if cfg.has_section("AUDIO") else {}
    g = cfg["APP"] if cfg.has_section("APP") else {}
    s.input_device_name = a.get("input_device_name", s.input_device_name)
    s.output_device_name = a.get("output_device_name", s.output_device_name)
    try:
        s.block_size_seconds = float(a.get("block_size_seconds", s.block_size_seconds))
        s.silence_threshold = float(g.get("silence_threshold", s.silence_threshold))
        s.caption_font_size = int(g.get("caption_font_size", s.caption_font_size))
    except ValueError:
        pass
    s.speech_speed = g.get("speech_speed", s.speech_speed)
    s.auto_start = str(g.get("auto_start", s.auto_start)).lower() in ("1", "true", "yes")
    return s


def save_settings(s: Settings) -> None:
    os.makedirs(USER_DIR, exist_ok=True)
    cfg = configparser.ConfigParser()
    if os.path.exists(USER_CONFIG):
        try:
            cfg.read(USER_CONFIG)
        except configparser.Error:
            cfg = configparser.ConfigParser()
    if not cfg.has_section("AUDIO"):
        cfg.add_section("AUDIO")
    if not cfg.has_section("APP"):
        cfg.add_section("APP")
    d = asdict(s)
    cfg["AUDIO"]["input_device_name"] = d["input_device_name"]
    cfg["AUDIO"]["output_device_name"] = d["output_device_name"]
    cfg["AUDIO"]["block_size_seconds"] = str(d["block_size_seconds"])
    cfg["AUDIO"]["sample_rate"] = "16000"
    # Old numeric IDs are no longer used; drop them to avoid confusion
    cfg.remove_option("AUDIO", "input_device_id")
    cfg.remove_option("AUDIO", "output_device_id")
    cfg["APP"]["silence_threshold"] = str(d["silence_threshold"])
    cfg["APP"]["speech_speed"] = d["speech_speed"]
    cfg["APP"]["auto_start"] = str(d["auto_start"])
    cfg["APP"]["caption_font_size"] = str(d["caption_font_size"])
    with open(USER_CONFIG, "w") as f:
        cfg.write(f)

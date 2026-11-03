import configparser
import os
import sys
import sounddevice as sd

CONFIG_FILE = "churchaitranslate.conf"


def list_and_select_device(kind):
    """Lists available audio devices for input or output and prompts for user selection."""
    devices = sd.query_devices()
    valid_devices = []

    print(f"\n==========================================")
    print(f"      AVAILABLE AUDIO {kind.upper()}S")
    print(f"==========================================")

    for idx, dev in enumerate(devices):
        # Filter input or output channels based on requested kind
        if kind == "input" and dev["max_input_channels"] > 0:
            valid_devices.append((idx, dev["name"]))
            print(f"  [{idx}] {dev['name']} (Inputs: {dev['max_input_channels']})")
        elif kind == "output" and dev["max_output_channels"] > 0:
            valid_devices.append((idx, dev["name"]))
            print(
                f"  [{idx}] {dev['name']} (Outputs: {dev['max_output_channels']})"
            )

    if not valid_devices:
        print(f"\n[!] Error: No valid audio {kind} devices found!")
        sys.exit(1)

    while True:
        try:
            choice = int(
                input(f"\nSelect the ID for your {kind.upper()} device: ")
            )
            selected = next(
                (dev for dev in valid_devices if dev[0] == choice), None
            )
            if selected:
                print(f"[✓] Selected {kind.capitalize()}: {selected[1]}")
                return choice, selected[1]
            else:
                print("[!] Invalid ID. Please choose a number from the list.")
        except ValueError:
            print("[!] Please enter a valid integer ID.")


def main():
    print("=== Church AI Translation Audio Configurator ===")

    # Select Devices
    input_id, input_name = list_and_select_device("input")
    output_id, output_name = list_and_select_device("output")

    # Create INI Config Parser
    config = configparser.ConfigParser()
    config["AUDIO"] = {
        "input_device_id": str(input_id),
        "input_device_name": input_name,
        "output_device_id": str(output_id),
        "output_device_name": output_name,
        "sample_rate": "16000",
        "block_size_seconds": "3",
    }

    config["MODELS"] = {
        "stt_model": "small.en",
        "translation_model": "facebook/nllb-200-distilled-600M",
        "tts_voice": "es_MX-ald-medium",
    }

    # Write configuration file to ~/ChurchAI
    config_dir = os.path.expanduser("~/ChurchAI")
    os.makedirs(config_dir, exist_ok=True)
    config_path = os.path.join(config_dir, CONFIG_FILE)
    with open(config_path, "w") as configfile:
        config.write(configfile)

    # Also save locally in script directory for portability
    local_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), CONFIG_FILE)
    try:
        with open(local_path, "w") as configfile:
            config.write(configfile)
    except Exception:
        pass

    print(f"\n==========================================")
    print(f"[✓] Configuration successfully saved to:")
    print(f"    {config_path}")
    print(f"==========================================")
    print(f"Input:  [{input_id}] {input_name}")
    print(f"Output: [{output_id}] {output_name}")
    print("==========================================\n")


if __name__ == "__main__":
    main()
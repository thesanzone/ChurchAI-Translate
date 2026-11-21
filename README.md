# Church AI Translation

Live English → Spanish translation for church services. It listens to a
microphone, writes down the English, translates it to Spanish, and speaks the
Spanish through speakers or headsets. Everything runs on the Mac with no
internet needed after setup.

## For volunteers: running a service

1. Plug in the audio interface (USB Audio Device) **before** opening the app.
2. Double-click **Church AI Translation.app**.
3. Wait for the status to change from *Loading…* to **Ready** (about 10–60 seconds).
4. Check the **Microphone** and **Speakers / headsets** lists show the right devices.
   If a device says *(not connected)*, check its cable and press **Refresh device list**.
5. Optional: press **Test speakers**. You should hear "Prueba de sonido. Uno, dos, tres."
6. Press the green **Start** button. The status light turns green.
7. When the pastor speaks, the **In** meter should bounce **above the dashed line**.
   Sound below the line is treated as silence and isn't translated.
8. Press **Show captions** to put large Spanish text on a projector or TV
   (it goes full screen on the second display; press Esc to close it).
9. At the end, press the red **Stop** button and close the window.

### What the screen tells you

| You see | What it means | What to do |
|---|---|---|
| Green dot, "Listening on…" | Working normally | Nothing |
| Amber dot, "no sound from the microphone" | Nothing heard for 20+ seconds | Check the mic is on, unmuted, and the mixer is sending to the interface |
| Red dot with a message | Something failed (e.g. device unplugged) | Read the message, fix the cable, press Start again |
| Clip light above the In meter turns red | Mic is too loud and distorting | Turn the mixer send down a little |
| In meter stays below the dashed line | Mic is too quiet | Turn the mixer send up, or lower the *Silence cutoff* in Settings |
| Delay turns amber/red | Translation is falling behind | Try *Speech speed: Fast* in Settings |

Transcripts of every session are saved automatically in
`~/ChurchAI/Transcripts` (press **Open transcripts**).

### Settings (gear)

- **Spanish speech speed**: Normal or Fast.
- **Listen in chunks of**: seconds of speech per translation (default 3). Shorter is quicker but may split sentences.
- **Silence cutoff**: how loud sound must be to be translated (the dashed line).
- **Caption text size**: font size for the projector window.
- **Start listening as soon as the app is ready**: hands-free start.

### Swear-word filter

Both apps (Python and Swift) check every phrase against **`word_filter.txt`** before
anything is spoken, shown in captions or saved. This protects against a misheard
English word or a translation accident (for example "coger", which means "take" in
Spain but is vulgar in Mexico).

- **[block]** words are never spoken or shown. Blocked English words appear as ••• in
  the transcript panel; blocked Spanish words are left out of the voice and captions.
  The Python app also stops the translation model from choosing these words at all.
- **[replace]** swaps risky words for safe ones (coger → tomar, shittim → acacia).
- **[allow]** keeps sermon and Bible words such as *hell*, *damnation* and *infierno*.

To add a word, open `word_filter.txt` in TextEdit, add it under the right heading, save,
and restart the app (the Swift app also needs rebuilding). Filtered words are never
written to the log or transcripts; the log just notes how many words were changed.

## For the person setting up the Mac

First-time setup needs a macOS **Administrator** account and an internet connection
(it downloads about 6 GB of AI models, mostly the NLLB-200 1.3B translation model). Double-click **Church AI Translation.app**:
if anything is missing, it opens Terminal and runs setup automatically, then opens
the window. After that, daily use does **not** need an admin account or Terminal.

To force a repair/reinstall, run in Terminal from this folder:

```bash
./start_translation.sh --setup
```

If the app won't open, the log is at `~/ChurchAI/logs/app.log`.

The first time you press Start, macOS asks for **microphone permission** for
"Church AI Translation". Click Allow. If it was denied, enable it in
System Settings → Privacy & Security → Microphone.

## Files in this folder

### Needed

| File | What it does |
|---|---|
| `Church AI Translation.app` | The double-click launcher. Opens the window, or runs setup the first time. |
| `app.py` | The desktop window (control panel, meters, transcript, captions). |
| `engine.py` | The translation engine: speech-to-text, translation, Spanish voice. |
| `app_config.py` | Loads/saves settings in `~/ChurchAI/churchaitranslate.conf`. |
| `word_filter.txt` | The swear-word list (block / replace / allow). Shared by both apps; safe to edit. |
| `word_filter.py` | Applies `word_filter.txt` in the Python app. |
| `start_translation.sh` | Launcher script used by the app: runs setup if needed, then opens the window. |
| `setup_mac.sh` | One-time installer (Homebrew, Python, AI packages, models). |
| `venv/` | Python environment and downloaded AI models. Created by setup; not in git. |

### Optional

| File | Notes |
|---|---|
| `Start Translation.command` | Same as the app, but always shows Terminal. Handy for troubleshooting. |
| `launcher.applescript` | Source code for the .app. Only needed if you want to change how the app launches. |
| `README.md` | This guide. |

### Archived (no longer used)

The `Archived/` folder keeps the old files for reference. Nothing in the app uses them,
and the folder can be deleted once you're happy with the new window.

| File | Why it was retired |
|---|---|
| `Archived/translator.py` | Replaced by `engine.py` + `app.py`. To use it as a Terminal-only fallback, move it back next to `venv/` first; it won't find the models from inside `Archived/`. |
| `Archived/configure_audio.py` | Replaced by the device lists in the window. |
| `Archived/churchaitranslate.conf` | Settings now live in `~/ChurchAI/churchaitranslate.conf`. |

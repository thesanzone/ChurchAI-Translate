# Church Translate 3 (Swift app for Mac and iPad)

A native Mac + iPad translator for church services. It listens to the preacher in English
and translates into **one or more languages at once**, each with its own voice, speaker
output and captions screen. Speech recognition, translation and voices are all Apple's
and run on the device. The Python app in the folder above is separate and not touched.

| Step | How |
|---|---|
| Speech to text | Apple Speech (`SpeechAnalyzer`), with a church vocabulary list |
| English → other languages | Apple Translation (about 25 languages; each is a one-time download) |
| Voices | Apple voices (Enhanced/Premium recommended; free one-time downloads) |
| Install | One app (~10 MB); Apple downloads the speech, translation and voice files once |

Requires **macOS 26** or **iPadOS 26** or newer.

## What's new in version 3.0.1

- **Support contact** in Settings → About: support@sanzlab.net. About also lists what changed.
- **iPad:** saved transcripts now appear in the Files app (On My iPad → Church Translate).
- **App Store preparation:** added the privacy details Apple requires (no data collected), made
  the iPad icon fully opaque, removed an unused internet permission, and set the version number
  in one place. Translation works the same as 3.0.

## What's new in version 3

- **Several languages at once** (Mac). The **Outputs** tab has one row per language:
  On, Language, Voice, Output device, Volume, Meter, Test and Remove. Rows can be dragged to
  reorder. On iPad, one language at a time.
- **Turning off vs removing.** Untick **On** to mute a language (its settings are kept).
  The trash button removes the row. During a service, removing a language that's on asks
  first ("Stop Korean and remove it?").
- **Everything is saved automatically** and restored next time the app opens. Version 2's
  Spanish settings (speakers, voice, volume) become the first row on the first launch.
- **The first language is always fastest.** Apple's translation works on one sentence at a
  time, so languages take turns in Outputs order: the top row gets each sentence first and
  the next rows follow (about +0.5–1 s each). One language runs about 1–1.5 s behind the
  preacher, as in version 2. **On an M1/M2 Mac, more languages add delay:** the second
  translation model competes with speech recognition for the Mac's Neural Engine, so
  recognition slows and the top language runs about 2–4 s behind (M2 MacBook Air, measured
  November 2026; with a fake second translation recognition stayed fast). **On an M4 there is
  no extra delay for the top language:** with 1–4 languages it stayed at 1.1 s average (worst
  1.5 s), and each further language follows about 0.5 s later (4th language 2.5 s average,
  worst 3.2 s; M2: 6.3 s, worst 8.5 s). For several languages, use an M4 (or newer) Mac.
  A language that
  falls more than 4 sentences behind skips ahead and shows a notice. The Translate tab shows
  each language's delay.
- **Captions on any external screen** (Mac): in **Settings → Captions**, pick a screen for each
  language (one language per screen). Captions open full screen there when you press
  Start (or **Show captions**), and come back by themselves if the screen is unplugged and
  replugged. AirPlay displays work too ("Use as Separate Display"). The screen with the
  menu bar is never used, so the controls stay visible.
- **Caption style:** font, size, background and text colour (green or blue for keying out
  in OBS Studio and similar), outline, top or bottom, and one or two lines. **Preview**
  shows the result with sample text before a service.
- **Mac's sound as an input** (Mac): choose "Mac's sound" in the Microphone menu to
  translate a video or livestream playing on the Mac (for testing without a live speaker).
  The app's own voices are always left out, so they're never translated again. The first
  time, macOS asks for permission to capture audio.
- **Piper removed.** All voices are Apple's, so the app no longer contains any GPL code.
- **More robust:** a USB audio device moved to another USB port is found again; an output
  device that isn't plugged in, or doesn't respond, no longer freezes the app or plays on
  the wrong speakers (that language keeps its captions and transcript and its voice starts
  when the device is back).

## Physical setup (how we use it)

The app needs an audio input (the preacher) and one audio output per language. Using the
Mac's own 3.5 mm headphone jack works, but we use a **USB audio adapter** instead: an
inexpensive (under $10) USB sound card with a line input and a line output. It plugs into a
**USB-C hub** that also powers the laptop, so a single USB-C cable connects or disconnects the
laptop from the whole setup.

```
Sound system line out ──(split)──► USB audio adapter IN ──► Mac running Church Translate
                                                                     │
Listeners: FM radio + headphones ◄── FM transmitter ◄── headphone amp ◄── USB audio adapter OUT
                                                              │
                                                     monitor headphones
```

1. **Input.** The sound system has a line output, split between several destinations. One
   feed goes to the USB adapter's input. It carries the preacher's microphone and anything else
   in the mix (more microphones, video playback). In the app, choose the USB adapter in the
   **Microphone** menu.
2. **Output.** The first language's translation goes out of the same USB adapter (choose it as
   that language's **Output** in the Outputs tab), through its 3.5 mm jack into a small
   **headphone amplifier**. A volunteer can plug headphones into the amplifier and listen to the
   translation before it reaches the listeners.
3. **To the listeners.** The headphone amplifier feeds a small **FM transmitter** for the room.
   People who need translation pick up a small FM radio and headphones when they arrive.

We use FM rather than Wi-Fi or a phone app because not everyone has a phone, and it greatly
reduces the tech support needed before and during services: listeners just tune a radio.

**More languages:** give each additional language its own USB audio adapter (all can share
the hub) and its own FM transmitter on a different frequency, then pick that adapter as the
language's Output. Label each radio or frequency with its language. For captions, a TV or
projector can connect to the hub's HDMI port.

**Products we use** (examples only; no affiliation with Amazon or the manufacturers):

| Part | Product |
|---|---|
| USB audio adapter (line in + out) | [SABRENT USB External Stereo Sound Card Adapter (AU-MMSA)](https://www.amazon.com/dp/B00IRVQ0F8) |
| USB-C hub | [Anker USB-C Hub](https://www.amazon.com/dp/B0BQLLB61B) |
| USB-C power adapter for the hub | [USB-C Power Adapter](https://www.amazon.com/dp/B0B1HJ666G) |
| FM transmitter | [FM Transmitter for Church and Home](https://www.amazon.com/dp/B0G7MB94RT) |
| FM radio for each listener | [Retekess portable FM radio with earphones](https://www.amazon.com/dp/B019BYBR48) |
| Headphone amplifier | Any small headphone amplifier with a 3.5 mm input and outputs |

## Running the Mac version (no Xcode needed)

```bash
cd SwiftApp
./build_mac_app.sh
open "build/Church Translate.app"
```

The first launch downloads Apple's English speech model (one time). Each language's
translation is a one-time download too: the Outputs tab shows a **Download** button.
macOS asks for microphone permission the first time you press Start. The app is signed only
locally, so after each rebuild macOS asks again; click **Allow**.

## Voices

Apple's voices start at basic quality, which sounds robotic. The Outputs tab warns about
these. For a natural voice, download an **Enhanced** or **Premium** voice for each
language (free):

- Mac: Settings tab → **Open Voice Settings…** → System voice menu → Manage Voices… → the
  language → tick an Enhanced or Premium voice. Then **Refresh Voices** in the Outputs tab.
- iPad: Settings → Accessibility → Spoken Content → Voices → the language.

## Swear-word filter

English swears are removed before translating (shown as ••• in the transcript). Spanish
translations are also checked against the Spanish part of **`../word_filter.txt`**
(shared with the Python app; rebuild after editing it). Other languages currently get the
English-side filter only.

```bash
"build/Church Translate.app/Contents/MacOS/ChurchTranslate" --filter-check "Coge tu cruz" "What the f*** happened"
```

## Testing from Terminal

Launch tests with `open -n -W --stdout <log> --stderr <log> "build/Church Translate.app" --args …`,
one at a time. Command-line tests never change the saved settings.

| Option | What it does |
|---|---|
| `--test-file=<audio>` | Translate a recording (MP3, M4A, WAV, MP4…) in real time. Use the `=` form: a separate path argument makes macOS treat it as a document and skip the window |
| `--quit-when-done`, `--mute` | Quit after the recording; run without sound |
| `--test-languages es,ko,pt` | Use these languages for this run |
| `--test-device-uids "uid1\|uid2"` | Output device per test language (`none` = Mac default) |
| `--timing` | Print how long recognition and each translation take |
| `--fake-second-translation` | Languages after the first wait 0.6 s instead of translating (shows how much a second translation model slows recognition) |
| `--test-mute-second N` | Turn the second language off after N s and on again after 2N s |
| `--test-captions` | Show the first language's captions on the first external screen |
| `--render-captions <folder>` | Draw sample captions screens in three styles to PNG files |
| `--system-audio` | Use the Mac's sound as the input |
| `--input-gain-db N`, `--output-gain-db N`, `--auto-level` | Fader tests |
| `--simulate-voice-stall` | A voice phrase never reports finished |
| `--simulate-recognizer-error` | Speech recognition fails after the first sentence |
| `--simulate-output-dropout` | The first language's output stops 4 s in |
| `--simulate-slow-output N` | Opening the first output takes N extra seconds (a stuck USB device) |
| `--test-mic 25 --simulate-mic-dropout` | The microphone silently stops 4 s in |
| `--rows-selftest` | 450 phrases on screen (checks only 200 are kept) |
| `CHURCH_TRANSCRIPTS_DIR=<folder>` (environment) | Save transcripts elsewhere, e.g. a full test disk |

macOS doesn't open windows while the screen is locked; the app still starts its engine, so
recording tests work either way.

## Building for iPad (needs Xcode)

1. Install **Xcode** from the Mac App Store and open it once to install the iOS components
   (or run `sudo xcodebuild -runFirstLaunch`).
2. Generate and open the project:
   ```bash
   brew install xcodegen
   cd SwiftApp
   xcodegen generate
   open ChurchTranslate.xcodeproj
   ```
3. Pick an iPad simulator (or a plugged-in iPad) and press Run. For a real iPad, sign in with
   an Apple ID under Signing & Capabilities.

## Files

| File | What it does |
|---|---|
| `Sources/ChurchTranslate/ChurchTranslateApp.swift` | App entry point, quit confirmation, test options |
| `Sources/ChurchTranslate/ContentView.swift` | Top bar (Start/Stop, status) and the Translate tab |
| `Sources/ChurchTranslate/OutputsTab.swift` | The Outputs tab (one row per language) |
| `Sources/ChurchTranslate/SettingsTab.swift` | The Settings tab (speech, captions, transcripts, about) |
| `Sources/ChurchTranslate/TranslatorModel.swift` | Runs the pipeline: recognition → translation queue → voices; transcripts; recovery |
| `Sources/ChurchTranslate/LanguageChannel.swift` | One language: its saved settings, translation session and voice |
| `Sources/ChurchTranslate/LanguageSupport.swift` | Language names, voice choice, the app's own phrases |
| `Sources/ChurchTranslate/Speaker.swift` | One language's voice on its own output device, with meter and recovery |
| `Sources/ChurchTranslate/AudioCapture.swift` | Microphone, Mac's sound or recording input; level meter |
| `Sources/ChurchTranslate/SystemAudio.swift` | "Mac's sound" input (Core Audio process tap) |
| `Sources/ChurchTranslate/AudioDevices.swift` | Lists and selects audio devices (Mac); audio session (iPad) |
| `Sources/ChurchTranslate/CaptionView.swift`, `CaptionStyle.swift` | Captions screens and their style |
| `Sources/ChurchTranslate/CaptionWindows.swift` | Places each language's captions on its screen (Mac) |
| `Sources/ChurchTranslate/CaptionPreview.swift` | The captions Preview |
| `Sources/ChurchTranslate/WordFilter.swift` | Applies `../word_filter.txt` |
| `Sources/ChurchTranslate/Meters.swift` | Level meter, fader and status dot |
| `Package.swift`, `build_mac_app.sh` | Build the Mac app with Apple's Command Line Tools |
| `Resources/make_icon.swift`, `make_icon.sh` | Draw and package the app icon |
| `project.yml`, `Resources/` | Xcode project definition, Info.plist and entitlements for Mac + iPad |

## Licensing

Since version 3 the app contains only this project's own code and Apple's system
frameworks (no Piper, eSpeak or other third-party code). Versions 2.0–2.4 included the Piper
voice with eSpeak NG (GPL v3); their source code stays available in this repository's history
and releases.

## Known limits

- Several languages at once is Mac only; on iPad one language plays at a time.
- On iPad, audio goes wherever iPadOS routes it (a plugged-in USB audio interface is used
  automatically) and captions fill the iPad screen (a connected TV mirrors it).
- Not yet tested on a real iPad.

# Church Translate (Swift prototype)

A native Mac + iPad version of the church translator. Speech recognition and
translation use Apple's on-device tools; on Mac the Spanish voice is the same Piper
voice as the Python app, built into the app. The Python app in the folder above is not touched.

| Step | Python app (current) | This Swift app |
|---|---|---|
| Speech to text | Whisper base.en | Apple Speech (`SpeechAnalyzer`), with a church vocabulary list |
| English → Spanish | NLLB-200 (2.4 GB) | Apple Translation framework |
| Spanish voice | Piper `es_MX-ald` | Mac: the same Piper voice, built in. iPad: Apple voices (Juan/Paulina Enhanced) |
| Install | Homebrew + Python + ~3 GB of models | One app (~105 MB on Mac); Apple downloads the speech/translation files once |

Requires **macOS 26** or **iPadOS 26** or newer.

## Running the Mac version (no Xcode needed)

```bash
cd SwiftApp
./fetch_piper.sh        # once: downloads the Piper engine + voice into Vendor/ (~90 MB)
./build_mac_app.sh
open "build/Church Translate.app"
```

`Vendor/` is not stored in git; run `./fetch_piper.sh` again on any new development Mac.
Without it the app still builds, but uses Apple's voices instead of Piper.

The first launch downloads Apple's English speech model (one time). macOS will ask
for microphone permission the first time you press Start.

### Comparing with the Python app

Use **Play recording…** to translate an audio file (MP3, M4A, WAV…) of a past sermon.
It plays in real time, so the meters, delay and voice behave like a live service, and
the transcript is saved to `~/Documents/Church Translate Transcripts`. Feed the same
recording to the Python app and compare the two transcripts.

From Terminal, the same test can run without sound and print the translations:

```bash
"build/Church Translate.app/Contents/MacOS/ChurchTranslate" --test-file sermon.m4a --mute --quit-when-done
```

### Piper voice & licensing

On Mac the default voice is **Piper — Mexican Spanish** (`es_MX-ald-medium`), the same
voice as the Python app, run by the [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
engine (version 1.13.8; version 2.x removed the eSpeak component Piper voices need).

- The voice was trained on the Ald Mexican Spanish dataset, released under the Unlicense
  (public domain).
- sherpa-onnx and ONNX Runtime are Apache 2.0 / MIT licensed.
- **eSpeak NG**, which converts text to pronunciations for Piper, is **GPL v3**. Because it
  is built into the Mac app, the Mac app as a whole must be shared under the GPL: if you
  give the app to others, also make this source code available (for example a public
  GitHub repo). The GPL v3 is generally considered incompatible with the App Store, so the
  iPad/App Store build uses Apple's voices instead and does not include Piper.

### Apple voices (iPad, or as an alternative on Mac)

Apple's built-in Spanish voices start at basic quality. For a much more natural voice,
download an **Enhanced** or **Premium** one (free):

- Mac: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices → Spanish (Mexico)
- iPad: Settings → Accessibility → Spoken Content → Voices → Spanish

Then reopen the app and choose the voice in **Settings**.

## Building for iPad (needs Xcode)

1. Install **Xcode** from the Mac App Store (free, large download).
2. Open it once to accept the license and install the iOS components.
3. Generate and open the project:
   ```bash
   brew install xcodegen
   cd SwiftApp
   xcodegen generate
   open ChurchTranslate.xcodeproj
   ```
4. Pick an iPad simulator (or a plugged-in iPad) at the top of Xcode and press Run.
   For a real iPad, Xcode asks you to sign in with an Apple ID under Signing & Capabilities.

## Files

| File | What it does |
|---|---|
| `Sources/ChurchTranslate/ChurchTranslateApp.swift` | App entry point; main window and the Mac caption window |
| `Sources/ChurchTranslate/ContentView.swift` | Control panel: Start/Stop, status, devices, meters, transcript, settings |
| `Sources/ChurchTranslate/TranslatorModel.swift` | Runs the pipeline: speech recognition → translation → voice; transcripts |
| `Sources/ChurchTranslate/AudioCapture.swift` | Microphone (or recording) input, level meter, audio conversion |
| `Sources/ChurchTranslate/SpanishSpeaker.swift` | Spanish voice output (Piper or Apple) and output meter |
| `Sources/ChurchTranslate/PiperVoice.swift` | Runs the built-in Piper voice (Mac builds only) |
| `Sources/ChurchTranslate/AudioDevices.swift` | Lists and selects audio devices (Mac); audio session (iPad) |
| `Sources/ChurchTranslate/Meters.swift` | Level meter and status dot |
| `Sources/ChurchTranslate/CaptionView.swift` | Large Spanish captions for a projector/TV |
| `Package.swift`, `build_mac_app.sh` | Build the Mac app with Apple's Command Line Tools |
| `fetch_piper.sh` | Downloads the Piper engine and voice into `Vendor/` (not in git) |
| `Resources/make_icon.swift`, `make_icon.sh` | Draw and package the app icon |
| `project.yml`, `Resources/` | Xcode project definition, Info.plist and entitlements for Mac + iPad |

## Known limits of this prototype

- The Mac caption window opens as a normal window: drag it to the projector screen and
  press Control-Command-F for full screen.
- On iPad, audio goes wherever iPadOS routes it (a plugged-in USB audio interface is
  used automatically); there is no device picker.
- Not yet tested on a real iPad.

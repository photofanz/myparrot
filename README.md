# 🦜 MyParrot

**Bot-free meeting recorder + transcriber for macOS.** Records both sides of your online meeting into one stereo file — the remote party on the **left** channel, you on the **right** — so every line is speaker-tagged for free. No diarization model, no meeting bot joining your call, nothing leaves your Mac.

[繁體中文說明 →](README.zh-TW.md)

![Main window — speaker-tagged transcript; the playing row shows a stereo waveform (top = them, bottom = you) — click anywhere to seek](docs/img/main-window.png)

<p>
<img src="docs/img/recording.png" width="560" alt="Recording — per-channel level meters, shortcuts printed right on the buttons">
</p>
<p>
<img src="docs/img/narrow-mode.png" width="260" alt="Narrow window (320pt)"> &nbsp;
<img src="docs/img/mini-mode.png" width="300" alt="Floating mini mode">
</p>

## What's new in 0.3.0

- **Waveform + playback progress** — playing a past recording draws a stereo waveform right in the row (top = them, bottom = you), so you can see who spoke when; click anywhere to seek, ▶⇄❚❚ pause/resume, ↻ replay when done. Waveforms are cached locally, so they're instant after the first play.
- **Keyboard shortcuts** — ⌘R start / ⌘P pause / ⌘E stop / ⌘N new / ⌘T transcribe / ⌘O Finder / ⌘1 window mode / ⌘L 3-min·full transcript / ⌘K collapse list / ⌘, settings — **printed on the buttons**, nothing to memorize.
- **Three window modes on one key** (⌘1): standard (remembers your size) → narrow 320pt → floating mini bar.
- **dB-scaled level meters** — normal speech lights more than half the bar, silence stays at one segment; no more "I'm talking but it looks dead".
- **`myparrot` CLI** — for terminal users and AI agents: `record / stop / status / transcribe / list / devices / config / hooks`, `--json` event stream; **hooks** hand the finished transcript to any command (e.g. Claude Code writing the minutes). See below.
- **Update notice** — one background check of GitHub Releases at launch; a new version shows only as a non-blocking banner (can be disabled in Settings; hits `api.github.com` only, sends nothing).
- Fixes: transcribing right after stopping no longer fails; two recordings in the same minute with the same title no longer overwrite each other; the document button opens the transcript once one exists.

## Why stereo-split?

"Who said what" is the hard part of meeting transcription. MyParrot sidesteps it with physics instead of ML: the other side comes from a system-audio tap, you come from the microphone, and each gets its own channel. Split the file, transcribe each track, interleave by time — perfect speaker attribution, fully offline.

## Features

- **The other side** — Core Audio **Process Tap** (macOS 14.4+): captures system audio with no driver, no kernel extension, no virtual audio device
- **You** — AVAudioEngine microphone capture that **survives device/route changes mid-recording** (auto-heal on configuration change + a liveness watchdog; hot-swap mics without stopping — the file stays continuous)
- **Live transcript** while recording — three swappable engines: macOS 26 **SpeechAnalyzer** (long-form streaming, automatic fallback to SFSpeechRecognizer on older systems), or a fully local **Whisper** engine (whisper.cpp + Metal, large-v3 family) for stronger mixed-language (Mandarin/English) accuracy — recording auto-upgrades to a higher-precision re-transcribe once you stop
- Whisper models download in-app (Settings) or drop a `ggml-*.bin` into Application Support yourself — nothing is bundled, nothing calls home unless you ask it to
- **Transcribe past recordings** → `.txt` + timestamped, speaker-prefixed `.srt`, with automatic simplified→traditional Chinese normalization on Whisper output
- **Offline echo cancellation** (optional, non-destructive — writes `*_aec.m4a`, never touches the original)
- Auto CAF→m4a conversion, quit-protection while recording, floating mini mode, input-gain with soft limiter
- UI in English / 繁體中文 / 简体中文 / 日本語 / 한국어
- A build stamp in the footer, so you always know exactly which build you're running
- **Privacy**: fully offline. The only network calls are the optional update check (GitHub Releases) and Whisper model downloads you trigger yourself

## Requirements

- **macOS 14.4+** (system-audio Process Tap API) — **macOS 26.1+ recommended** for live transcription (26.0 has a known process-tap regression)
- **Swift 6 toolchain** — Xcode **Command Line Tools are enough** to build, run, and self-test. Full Xcode is only needed for `swift test`.
- **cmake** (`brew install cmake`) — one-time only, to build the local Whisper engine from source (see Quick start)

## Download

Grab the latest signed & notarized build from **[Releases](https://github.com/tingyulu/MyParrot/releases/latest)** — download the `.zip`, unzip, drag `MyParrot.app` into `/Applications`. No build tools needed; Gatekeeper won't complain (Developer ID signed + notarized).

Prefer to build from source? See below.

## Build from source

```bash
git clone <this-repo> && cd MyParrot
bash scripts/fetch-whisper.sh   # one-time: builds the local Whisper engine from source (~5-10 min, needs Xcode + cmake)
swift build                     # compile check
bash scripts/build-app.sh       # assemble, sign, install to ~/Applications
open ~/Applications/MyParrot.app
```

First launch asks for **Microphone**, **Speech Recognition**, and **System Audio Recording** permissions (it will *not* ask for Screen Recording).

## ⚠️ Gotchas (read these, they will save you an hour)

1. **Signing & permission persistence.** macOS ties permission grants (TCC) to the signing identity. `build-app.sh` auto-picks the best available: an Apple Development / Developer ID certificate (has a Team ID → **permissions survive rebuilds**) → a self-signed cert → ad-hoc (**permissions re-asked on every rebuild**). If you have any Apple certificate, the script will find and use it.
2. **Keep the `.app` out of iCloud-synced folders.** iCloud Drive re-applies Finder xattrs that repeatedly break code signatures. This is why the script installs to `~/Applications`.
3. **Don't use a Bluetooth mic.** The moment any app opens a Bluetooth microphone, the whole link drops from A2DP to narrowband HFP — the *other side's* audio degrades to phone quality too. Wear the headset for listening; speak into the built-in or a wired/USB mic. (MyParrot's auto-selection already avoids Bluetooth mics; picking one manually is allowed but warned.)
4. **First `swift build` fails right after clone?** Run `bash scripts/fetch-whisper.sh` first. The Whisper engine binary (~35MB) isn't checked into git — the script builds it from source once (needs Xcode + `cmake`).

## `myparrot` CLI (since 0.3.0)

```bash
bash scripts/build-cli.sh        # build + sign, installs ~/bin/myparrot (Whisper engine borrows the framework from ~/Applications/MyParrot.app)
myparrot                          # in a terminal: interactive menu (pick mic, record, watch levels)
myparrot record --name "Weekly sync" --max-duration 2h   # foreground; Ctrl-C or `myparrot stop` from another terminal
myparrot transcribe "~/Documents/MyParrot/2026-08-20 1400 Weekly sync.m4a"
myparrot list --json | jq .       # for agents/scripts: one JSON event per line, zero ANSI when not a TTY
```

**Hooks** — the `hooks` section of `~/.config/myparrot/config.json` hands the transcript to any command after a recording ends (automatically, or on demand via `myparrot hooks run`). Placeholders `{audio}` `{transcript}` `{name}` `{dir}`; full metadata arrives as JSON on stdin. Approve once with `myparrot hooks approve` (trust-on-first-use; re-approve after edits).

```jsonc
{
  "hooks": {
    "minutes": {   // runs once the transcript is ready — let Claude Code write the minutes
      "command": "claude -p \"Read {transcript} and write a one-page meeting summary to {dir}/{name}.md\"",
      "cwd": "~/Documents/MyParrot",
      "auto": true
    }
  }
}
```

A `transcribe` hook can **replace** the built-in transcription (bring your own ASR) and falls back to the built-in engine on failure; another template is to drop a "recording ready" card into an existing AI session / todo system that picks it up. Permissions are attributed to your terminal app (it will ask for Microphone / System Audio once).

## Known limitations

| Area | Status |
| --- | --- |
| Long meetings (>30 min) | The two capture clocks drift slowly; sample-accurate sync is planned |
| Bluetooth headset as *output* while any app holds a BT mic | Phone-quality ceiling — protocol limitation (HFP), not fixable in software |
| Hot-swapping *to* a Bluetooth mic mid-recording | One audible pop at the switch (OS profile change) |
| Capture gaps shorter than 0.3 s | Not silence-padded (trade-off that eliminates padding clicks); the track may shift ≤0.3 s early in that window |
| Echo cancellation | Offline post-process only, off by default |

## Legal

Recording calls without consent is illegal in many jurisdictions. **You are responsible** for informing participants and obtaining consent where required.

## Architecture

```
Sources/MyParrotCore/        Library: capture, mux, transcription, export
  SystemAudioCapture.swift   Other side: global process tap (+ true-rate relabeling for BT/HFP)
  MicCapture.swift           You: AVAudioEngine + configuration-change self-heal
  StereoRecorder.swift       Two feeds → one stereo file (L=them, R=you), min-paced drain
  AudioUtils.swift           SampleQueue (ramped padding), 48 kHz mono converter, RMS
  RecordingController.swift  State machine, device watchdog, conversion, playback
  EchoCleanup / EchoCanceller / DelayEstimator   Offline AEC (bulk-delay + NLMS)
  Transcription/             SpeechAnalyzer (live + file) + SFSpeech fallback,
                              local Whisper engine (whisper.cpp/Metal) + model manager
  SelfTest.swift             15 self-test cases (shared by CLI runner & swift test)
Sources/MyParrot/            SwiftUI app (main window, mini mode, settings, mascot)
Sources/MyParrotSelfTest/    CLI test runner — works with Command Line Tools only
Tests/MyParrotTests/         Swift Testing wrappers (one @Test per self-test case)
scripts/build-app.sh         Assemble + sign + install + build stamp
```

See [docs/TESTING.md](docs/TESTING.md) for the test pyramid and how to verify changes.

## Author

Eric Lu ("Uncle Eric") — 30 years in product, now a product consultant, headhunter, and career coach. Several online interviews a week, and inviting a bot into the call always felt wrong — so I built this instead.

- Long-form writing: [uncleric.com](https://www.uncleric.com) (zh-TW)
- Find me: [Threads @tingyulu](https://www.threads.com/@tingyulu) | [LinkedIn](https://www.linkedin.com/in/uncleeric/)

## License

MIT © 2026 Eric Lu — see [LICENSE](LICENSE).

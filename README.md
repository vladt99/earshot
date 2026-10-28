<p align="center"><img src="docs/icon.png" width="128" alt="Earshot icon"></p>

<h1 align="center">Earshot</h1>

**Private meeting transcripts for macOS.** Earshot notices when a call starts in Google Meet, Zoom, Teams, Webex,
Slack or FaceTime, records the meeting audio and your microphone, and transcribes both live, with speaker names.
It all runs on your Mac: no bot joins the call and no audio leaves the machine. A local HTTP API, webhooks and an
MCP server let your other apps and agents use the transcripts.

![Overview](docs/screenshots/overview.png)

<p align="center"><b><a href="https://github.com/vladt99/earshot/releases/latest/download/Earshot.zip">⬇ Download Earshot for macOS</a></b> · <a href="https://github.com/vladt99/earshot/releases">All releases</a></p>

## Features

- **Live meeting transcription.** Calls are detected from the macOS microphone indicator, so it works with any
  meeting app, including Google Meet in a browser. The other participants (the app's audio) and you (the mic) are
  captured as separate tracks, so you are always labelled correctly.
- **Speaker names.** Other participants are separated into Speaker 1, 2, … and, with captions on in Google Meet,
  named after the people in the call. Voices you name once are recognised in later meetings.
- **Clean final transcript.** When the call ends, the live text is saved right away. Both recordings are then
  re-transcribed in one pass with full context, which takes about a minute for an hour-long call.
- **Note taking.** Press ⌃⌘B from any app to bookmark a moment, or type notes in the live panel. They are saved on
  the transcript's timeline.
- **Custom vocabulary.** Teach it names and jargon ("Kubernetes", your colleagues' names) and it corrects them.
- **Reliable capture.** Echo cancellation keeps the other side out of your mic track when you're not on
  headphones. Capture follows you when you switch to AirPods or another mic, you get a warning when an input goes
  silent, and a meeting interrupted by a crash or power loss is recovered on the next launch.
- **Everything else you'd expect:** file and folder transcription (audio, video, YouTube links), voice memos,
  dictation, live captions, a full-text search, folders, people, export to TXT, SRT, VTT, Markdown and JSON, and
  auto-export to a folder (an Obsidian vault works well).
- **Built for automation:** an OpenAI-compatible local API, live Server-Sent Events, signed webhooks, an MCP server
  for Claude and other agents, and a URL scheme for Shortcuts, Raycast and Alfred.

| Live transcript | Transcript |
|---|---|
| ![Live panel](docs/screenshots/live-panel.png) | ![Transcript](docs/screenshots/transcript.png) |

| Meetings | Settings |
|---|---|
| ![Meetings](docs/screenshots/meetings.png) | ![Settings](docs/screenshots/settings.png) |

## System requirements

| | |
|---|---|
| **macOS** | 26 Tahoe or later |
| **Mac** | Apple silicon (M1 or later). Intel Macs are not supported |
| **Memory** | 8 GB minimum, 16 GB recommended for long meetings |
| **Disk** | About 650 MB for the app and speech models, plus about 230 MB per hour of recorded meeting |
| **Network** | Only on first launch, to download the speech models (≈ 525 MB) from Hugging Face |
| **Languages** | 25 European languages, with automatic detection (Parakeet TDT v3) |
| **Speaker names from captions** | Google Meet in Chrome or another Chromium browser (Edge, Brave, Arc, Vivaldi), with captions (CC) on |

## Install

1. [**Download Earshot.zip**](https://github.com/vladt99/earshot/releases/latest/download/Earshot.zip) from the
   latest release.
2. Unzip it and drag **Earshot.app** to your **Applications** folder.
3. Open it. Earshot isn't notarized yet, so the first time macOS will say it can't verify the developer. Go to
   **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. Or run this once in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Earshot.app
   ```

4. Grant the permissions when asked:

   | Permission | Why |
   |---|---|
   | Microphone | Your side of the call, dictation and voice memos |
   | Screen & System Audio Recording | The meeting app's audio (the other participants). Only audio is captured |
   | Accessibility *(optional)* | Reading Google Meet's captions to name speakers. Settings → Note Taker → Grant Access |
   | Calendar *(optional)* | Naming meetings after the current calendar event |
   | Notifications | "Meeting detected" alerts and finished transcripts |

5. Leave it running while the speech models download (≈ 525 MB, shown on the Overview). It then lives in the menu
   bar and asks you when a call starts. To record calls automatically, go to Settings → Record Meetings.

To update, replace the app in Applications. Your transcripts, settings and models are kept.

To uninstall, delete the app and, if you want to remove your data as well,
`~/Library/Application Support/Earshot` (transcripts and recordings) and
`~/Library/Application Support/FluidAudio/Models` (speech models).

## Using it with Google Meet

1. Join the call in your browser. Earshot shows **Meeting detected**. Click **Transcribe**, or pick
   "Record automatically" in Settings → Record Meetings.
2. Turn on **captions (CC)** in Meet if you want real names instead of Speaker 1, 2, …. Earshot only uses the
   captions to see who is speaking. The transcript text comes from its own model.
3. Use headphones if you can. Echo cancellation helps on laptop speakers, but headphones give the cleanest audio.
4. Leave the call. Earshot stops 10 seconds later, saves the transcript and replaces it with the polished version
   about a minute later.

macOS gives one audio stream for the whole browser, so a video playing in another tab of the same browser ends up
in the transcript. Run Meet in a different browser from the one you use for media.

## Models and storage

Nothing is bundled with the app. Each model downloads once from Hugging Face:

| Model | Used for | Size | When |
|---|---|---|---|
| [Parakeet TDT v3](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | Transcription, live and files | 483 MB | First launch |
| [Pyannote Community-1](https://huggingface.co/FluidInference/speaker-diarization-coreml) | Telling speakers apart | 22 MB | First launch |
| LocalVQE v1.3 | Microphone echo cancellation | 20 MB | First launch |
| [Parakeet CTC 110M](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml) | Custom vocabulary | 100 MB | When you add the first word |

Models live in `~/Library/Application Support/FluidAudio/Models/`; Settings → Local Models shows them and can
delete or re-download each one. Transcripts and recordings are in `~/Library/Application Support/Earshot/`. Each
meeting has its own folder with `others.wav` (the other participants) and `me.wav` (you).

## Local API

Earshot serves an API on `http://127.0.0.1:7788` that is only reachable from your Mac. Every route except `/health`
needs `Authorization: Bearer <token>`. Apps find the token and URL in
`~/Library/Application Support/Earshot/api.json` (readable only by you). Requests carrying a browser `Origin`, or a
`Host` other than loopback, are refused, so web pages can't reach it. To change the port, run
`defaults write io.github.vladt99.Earshot port -int 9000`.

```sh
TOKEN=$(jq -r .token ~/Library/Application\ Support/Earshot/api.json)

# Transcribe a file (OpenAI-compatible)
curl -s localhost:7788/v1/audio/transcriptions -H "Authorization: Bearer $TOKEN" -F file=@memo.m4a

# A local file by path, as subtitles, with speakers
curl -s localhost:7788/v1/audio/transcriptions -H "Authorization: Bearer $TOKEN" \
     -d '{"path":"~/Movies/call.mp4","response_format":"srt","diarize":true}'

# Follow a meeting live
curl -sN "localhost:7788/v1/events?filter=meeting." -H "Authorization: Bearer $TOKEN"
```

The OpenAI SDKs work with `base_url="http://127.0.0.1:7788/v1"` and the token as the API key.

### Transcription

| Method & path | What |
|---|---|
| `GET /health` | `{ok, version, loaded_model}`, no auth |
| `GET /v1/status` | Engine state, model, downloads, active jobs, dictation |
| `POST /v1/audio/transcriptions` | OpenAI-compatible. Multipart `file` + `model`, `language`, `response_format` (`json`, `text`, `srt`, `vtt`, `verbose_json`), or JSON `{"path": "/abs/file"}` for local files. Extras: `save` (default true), `title`, `translate`, `diarize`. Synchronous |
| `POST /v1/audio/translations` | Same, translated to English |
| `POST /v1/jobs` · `GET /v1/jobs` · `GET /v1/jobs/{id}[?wait=true]` | Asynchronous version; the transcript is included once the job is `done` |
| `POST /v1/import/url` `{"url"}` | YouTube page (needs `brew install yt-dlp`) or direct media URL → job |

### Library

| Method & path | What |
|---|---|
| `GET /v1/transcripts?limit=&offset=&q=&origin=` | History; `origin` is one of `meeting`, `dictation`, `voicememo`, `api`, `app`, `watch`, `youtube`, `appaudio`, `podcast` |
| `GET /v1/transcripts/{id}?format=` | One transcript in any format |
| `POST /v1/transcripts/{id}/translate` `{"target": "de"}` | On-device translation |
| `DELETE /v1/transcripts/{id}[?permanent=true]` | Move to Recently Deleted, or delete for good |
| `GET /v1/search?q=&limit=&origin=` | Full-text search; each hit has a `snippet` and the matching lines with speaker and time |
| `POST /v1/transcripts/{id}/speakers` `{"from": "Speaker 1", "to": "Maya"}` | Rename a speaker; for meetings this also remembers Maya's voice |
| `GET /v1/voices` · `DELETE /v1/voices/{name}` | Remembered voices |

### Meetings and live events

| Method & path | What |
|---|---|
| `GET /v1/events[?filter=meeting.,job.]` | Server-Sent Events: `meeting.detected`, `meeting.started`, `meeting.partial`, `meeting.segment`, `meeting.speakers_revised`, `meeting.note`, `meeting.warning`, `meeting.capture_restarted`, `meeting.ended_detected`, `meeting.saved`, `meeting.polishing`, `meeting.finalized`, `meeting.retranscribed`, `meeting.recovered`, `job.done`, `job.failed` |
| `GET /v1/meetings/current[?format=text]` | The running meeting's live transcript, notes and warnings |
| `POST /v1/meetings/current/notes` `{"text"}` · `POST /v1/meetings/current/bookmark` | Add a note or bookmark now |
| `GET /v1/meetings/detected` | The app currently detected as being in a call |
| `POST /v1/meetings/start` `{"app"?: bundle id or "system", "title"?, "mic"?: true}` | Start recording (defaults to the detected app) |
| `POST /v1/meetings/stop` | Stop and save. Returns the live transcript with `"polishing": true`; the final version arrives as `meeting.finalized` |
| `GET /v1/meetings` | Saved meetings |
| `POST /v1/meetings/{id}/retranscribe` | Re-transcribe both recordings at full quality |

### Models, settings, dictation

| Method & path | What |
|---|---|
| `GET /v1/models` | Every model with `installed`, `bytes_on_disk`, `download_bytes`, `path` |
| `POST /v1/models/download` `{"model"}` · `DELETE /v1/models/{id}` | Download or remove `parakeet-tdt-v3`, `speaker-diarization`, `localvqe`, `parakeet-ctc-110m` |
| `GET` / `PATCH /v1/settings` | `meeting_mode` (`ask`, `auto`, `off`), `meeting_apps`, `auto_stop_after_meeting`, `auto_dismiss_meeting_alerts`, `diarize_meetings`, `diarize_files`, `participants_name`, `my_name`, `echo_cancellation`, `language`, `watched_folders`, `polish_after_meeting`, `auto_name_speakers`, `remember_voices`, `vocabulary`, `bookmark_hotkey`, `audio_warnings`, `webhooks`, `webhook_events`, `auto_export_folder`, `auto_export_formats` |
| `GET /v1/dictation` · `POST /v1/dictation/start` · `stop` · `cancel` | Microphone dictation; `stop` returns the transcript |

`language` takes an ISO 639-1 code or `auto`. The OpenAI `model` field is accepted and ignored. Errors use OpenAI's
shape: `{"error": {"message", "code"}}`.

### Webhooks

Settings → Integrations takes a list of URLs and the events to send (by default `meeting.finalized` and `job.done`,
both of which include the full transcript). Each POST carries `X-Earshot-Event` and
`X-Earshot-Signature: sha256=<HMAC-SHA256 of the body, keyed with the API token>`. Failed deliveries are retried
twice.

### MCP server

The app bundle includes an MCP server that lets Claude and other agents search and read your meetings:

```sh
claude mcp add earshot -- /Applications/Earshot.app/Contents/MacOS/earshot-mcp
```

Tools: `search_transcripts`, `list_meetings`, `get_transcript`, `current_meeting`, `start_meeting`, `stop_meeting`,
`add_meeting_note`, `transcribe_file`. Earshot must be running.

### URL scheme

`earshot://meeting/start[?app=com.google.Chrome|system&title=…&mic=false]` · `meeting/stop` · `meeting/toggle` ·
`dictation/toggle` · `transcribe?path=/abs/file` · `open?id=<transcript id>` · `show?page=meetings` ·
`settings?page=Record%20Meetings` · `panel`

## Build from source

You need macOS 26, Apple silicon and Xcode 26 (Swift 6.2).

```sh
git clone https://github.com/vladt99/earshot.git
cd earshot
./build.sh            # release build → dist/Earshot.app
./build.sh --open     # build and launch
./build.sh --install  # build, copy to /Applications and launch
./build.sh --zip      # build and pack dist/Earshot.zip for a release
```

Builds are signed ad hoc, so macOS asks for permissions again after every rebuild. To keep them, sign with a stable
identity: create a `.signing.env` (git-ignored) with `SIGN_IDENTITY="Your Certificate Name"`, plus `SIGN_KEYCHAIN`
and `SIGN_KEYCHAIN_PASSWORD_FILE` if the certificate is in its own keychain.

For debugging live transcription, run `defaults write io.github.vladt99.Earshot liveDebug -bool true`; the log is
written to `~/Library/Application Support/Earshot/live-debug.log`.

### Source layout

```
Sources/Earshot/
  App.swift              scenes: main window, Settings, menu bar
  AppState.swift         observable app state, navigation, library actions
  UI/Theme.swift         backdrop, glass cards, shared components
  UI/MainWindow.swift    sidebar, toolbar, routing
  UI/HomeView.swift      overview, quick start, App Audio picker, Batch Export
  UI/LibraryViews.swift  transcript lists, Recently Deleted, Queue
  UI/DetailView.swift    transcript editor and segments, inspector, playback
  UI/SettingsWindow.swift  settings pages
  Views.swift            menu bar panel
  MeetingPanel.swift     floating live transcript, notifications
  MeetingDetector.swift  call detection, calendar titles
  Meeting.swift          meeting sessions, live transcription, live speakers, notes, watchdog, final pass
  Notetaker.swift        crash recovery, speaker naming (captions, voices), bookmark hotkey
  MeetCaptions.swift     Google Meet captions through the accessibility tree
  AudioCapture.swift     Core Audio process tap, ring buffer, gap filling, microphone
  Engine.swift           FluidAudio: Parakeet, diarization, custom vocabulary
  Jobs.swift             transcription queue
  Dictation.swift        dictation and voice memos
  Store.swift            SQLite library with FTS5 search
  PostProcess.swift      ignored segments, find & replace, auto-export
  Extras.swift           watched folders, URL import, translation, URL scheme
  Webhooks.swift         signed event delivery
  HTTPServer.swift, API.swift, Events.swift, Formats.swift, Models.swift, Settings.swift
Sources/EarshotMCP/main.swift   MCP server (stdio) over the local API
```

## How it works

- **Call detection.** Earshot follows Control Center's microphone-in-use attributions from the system log. When a
  known meeting app (or a browser) holds the microphone, that's a call. A call only counts as ended after the app
  has released the mic for 4 seconds. There is no polling and no reading of browser URLs.
- **Capture.** The meeting app's output is captured with a Core Audio process tap on a private aggregate device,
  including helper processes (Chrome renderers, Teams helpers, Safari's WebKit GPU process). The microphone is
  recorded separately and passed through LocalVQE echo cancellation, with everything the Mac plays as the
  reference.
- **Live transcription.** Each track has its own streaming transcriber: Parakeet runs on voice activity, and text is
  confirmed once consecutive passes agree on it. Speakers on the app track come from pyannote, re-run as the
  recording grows.
- **Final pass.** After the call, both recordings are transcribed in full. Speakers are named from Meet caption
  hints and remembered voices, and custom vocabulary is applied.

## Status and known limitations

Earshot is young (0.8). What has been tested and what hasn't:

- Tested: call detection, live and final transcription, speaker separation, remembered voices, bookmarks and
  notes, crash recovery, search, export, webhooks, the API and the MCP server.
- Not yet tested in real calls: naming speakers from Google Meet captions (it depends on Meet's page structure,
  which Google can change), switching audio devices mid-call, and the silent-input warnings. Reports are welcome.
- Live speaker labels can change during the first minute while the model learns the voices. The final pass is more
  accurate.
- On laptop speakers without headphones, some of the other side can still reach your microphone track.
- macOS gives one audio stream per browser, so other tabs playing sound end up in the meeting recording.
- The app isn't notarized yet, so macOS needs one manual confirmation on first launch.

## Privacy

Audio, transcripts and voice profiles stay on your Mac. Earshot connects to the internet only to download models
from Hugging Face, to fetch a YouTube link you paste, and to send webhooks you configure yourself. The API only
listens on 127.0.0.1.

## Credits

- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0) for on-device speech recognition,
  diarization and echo cancellation on Core ML
- [NVIDIA Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC BY 4.0)
- [pyannote](https://github.com/pyannote/pyannote-audio) speaker diarization (MIT)

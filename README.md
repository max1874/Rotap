# Rotap

English | [简体中文](README.zh-CN.md)

Record what your Mac is playing — every app or just one — optionally mixed with your microphone. A native macOS app: no virtual audio driver, no changes to your speaker or headphone setup.

## Features

- **Three capture modes**: system audio only, microphone only, or system audio + microphone mixed into one file.
- **Pick a source**: all system audio, or a single app that is currently playing.
- **Formats**: M4A (AAC) or WAV (24-bit).
- **Waveform**: drawn live while recording; after recording, click or drag on it to seek.
- **Stays out of the way**: listens through a Core Audio process tap, so your output device keeps working and what you hear is unchanged.

## Download

Get the latest `Rotap-<version>.dmg` from [Releases](https://github.com/max1874/Rotap/releases) and drag Rotap into Applications. The disk image is signed with a Developer ID and notarized by Apple.

Requires **macOS 26** or later. The app's interface is currently in Chinese only.

## Permissions

| Permission | Asked when | Used for |
| --- | --- | --- |
| System audio recording | The first time you record system audio | Reading the sound other apps play |
| Microphone | The first time you record the microphone | Recording your voice |

Recordings are saved only on your Mac (`~/Music/Rotap` by default, changeable in Settings). Rotap makes no network connections and uploads nothing.

## Building from source

Requires Xcode 26 or later.

```sh
make app          # maintainer build: Developer ID signed, output at build/Rotap.app
```

Without the maintainer's certificate, build with an ad-hoc signature:

```sh
xcodebuild -project Rotap.xcodeproj -scheme Rotap -configuration Release \
  -destination 'generic/platform=macOS' CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

macOS treats every rebuild of an ad-hoc signed app as a new app and asks for the permissions again.

`make release` / `make install` are the maintainer's release flow (signing, notarization, publishing a release) and depend on tooling outside this repository.

## How it works

- `Audio/AudioRecorder.swift`: the process tap and the microphone share one private aggregate device and therefore one clock. The real-time IO thread only mixes; a lock-free ring buffer hands the audio to a writer thread that encodes and writes it.
- `Audio/Waveform.swift`: the waveform is built while recording and stored in the file's extended attributes, so opening an old recording needs no re-analysis.
- `Views/WaveformLayers.swift`: waveforms are drawn with Core Animation layers, keeping the UI's CPU use low while recording.

## License

[MIT](LICENSE)

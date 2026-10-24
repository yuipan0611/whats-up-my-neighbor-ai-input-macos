<p align="center">
  <a href="https://nekonode.cloud">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/media/brand/app-icon.svg">
      <img src="docs/media/brand/neko-round-face.svg" alt="What's up my neighbor black cat logo" width="150">
    </picture>
  </a>
</p>

<h1 align="center">What's up my neighbor</h1>

<p align="center">
  <b>Say what's on your mind.</b><br>
  A black cat in your Mac menu bar that turns your voice into text, right where you were typing.
</p>

<p align="center">
  <a href="https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/actions/workflows/build.yml"><img src="https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <a href="https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/releases/latest"><img src="https://img.shields.io/github/v/release/yuipan0611/whats-up-my-neighbor-ai-input-macos" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-101114?logo=apple" alt="macOS 13+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT"></a>
  <a href="https://nekonode.cloud"><img src="https://img.shields.io/badge/website-nekonode.cloud-101114" alt="Official website nekonode.cloud"></a>
</p>

<p align="center">
  <a href="https://nekonode.cloud"><b>Website</b></a> ·
  <a href="https://nekonode.cloud/#download">Download</a> ·
  <a href="https://nekonode.cloud/guide">Guide</a> ·
  <a href="docs/GUIDE.md">Full manual</a> ·
  <a href="https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-windows">Windows</a>
</p>

<p align="center">
  Language:
  <a href="README.md"><kbd>繁體中文</kbd></a>
  <a href="README.en.md"><kbd>English ✓</kbd></a>
  <a href="README.ja.md"><kbd>日本語</kbd></a>
</p>

---

> [!NOTE]
> The app's interface, the official website and the full manual are currently in **Traditional Chinese only**. Chinese file names below keep their original text with a translation in brackets, so you can match them to what you see.

What's up my neighbor is a lightweight, native macOS menu bar dictation app. Press `⌥↑` in any text field to start recording and press it again to stop. The audio is transcribed by Groq `whisper-large-v3` and pasted back at your cursor. While you talk, a little black cat keeps you company on screen.

<p align="center">
  <img src="docs/media/screenshots/recording-hud-card.png" alt="The recording overlay: a black cat whose volume bars bounce between its ears; the X eye cancels and the check-mark eye finishes" width="420">
</p>

## Features

- **One shortcut, back where you were**: `⌥↑` by default and fully customisable. The text is pasted into the field you started from.
- **Black cat recording overlay**: volume bars follow your voice. Click the left (X) eye to cancel or the right (✓) eye to finish. The overlay never steals focus from your text field.
- **Three output modes**: Verbatim (default), Standard and Concise. All of them are fixed local rules, not a rewriting model, and legal terms and article numbers are never altered.
- **Language guard**: pick one primary language plus up to two mixed-in languages from Traditional Chinese, English, Japanese, Korean, Thai, Vietnamese, Spanish, French and German. Text in a language you didn't allow is held back and retried once instead of being pasted.
- **Clipboard history**: your last 10 entries, opened with `⌃⌥V`. Enter only pastes, it never sends the message.
- **Desktop cat**: she strolls, licks her paw, yawns and naps. Click her and a purr bubble pops up; click and drag to pick her up.
- **Privacy first**: your API key lives only in the macOS Keychain. There is no analytics, no ads and no backend of our own.
- **You decide when to update**: Sparkle checks for new versions daily and asks before installing. Your settings are never overwritten.

### QA features (not yet released)

- **Command+V history gesture**: a normal tap of `⌘V` pastes as usual. Hold `⌘V`, then press `↑` or `↓` to open history. Enter confirms, Esc closes; `⌃⌥V` and the menu entry remain available.
- **Nine coats, applied immediately**: choose “選擇貓咪花色” (Choose cat coat) from the menu bar. The real desktop cat changes coat and appears if hidden, without restarting. The original black cat is the default, and your selection is remembered.
- **Custom cat packs**: customise each eye, the nose, a collar and a bow, then import or export a `.nekocat` file. A custom delivery can include a selected cat for first use. [Format, delivery and QA (Traditional Chinese)](docs/CAT-PACKS.md).

Release 1.4.5 does not include these features. The QA installer adds a “QA 測試版” label and source revision to the menu. [Installation and desktop QA steps (Traditional Chinese)](docs/QA_CLIPBOARD_CAT.md).

## Screenshots

<p align="center">
  <img src="docs/media/screenshots/greeting-card.gif" alt="Say what's up to the cat and she answers what's up! in a speech bubble" width="400">
  &nbsp;&nbsp;
  <img src="docs/media/screenshots/desktop-pet-walking-card.gif" alt="The desktop cat walking" width="250"><br>
  <sub>Say just <code>what's up</code> and the cat replies (the phrase is not typed into your text field). Let her out and she wanders and rests along the edge of your screen.</sub>
</p>

<p align="center">
  <img src="docs/media/screenshots/desktop-pet-poses.png" alt="Seven desktop cat poses: sitting, standing up, walking, curious, licking a paw, yawning and lying down" width="820"><br>
  <sub>After about 12 seconds without input she changes pose on her own; she pauses while you record, go full screen or lock the Mac</sub>
</p>

<p align="center">
  <img src="docs/media/screenshots/desktop-pet-interaction.png" alt="Left: after a click the cat closes her eyes and purrs. Right: while dragged she is lifted off the ground" width="820"><br>
  <sub>Click her and she purrs in a speech bubble; click and drag to pick her up, then let go to set her down</sub>
</p>

## Install

**Requirements**: macOS 13 Ventura or later, your own Groq API key, an internet connection, and Microphone and Accessibility permissions.

### Download the ZIP

1. Download `Groq-AI-Voice-Input-macOS-v<version>.zip` from [Releases](https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/releases/latest) and unzip it. `Neighbor-macOS-<version>.zip` on the same page is the in-app update package; you don't need it.
2. The first time, right-click `安裝.command` (Install) and choose **Open**, because the free build is not notarised by Apple. If macOS still blocks it, go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. Follow the first-launch window to paste your own Groq API key, then allow Microphone and Accessibility access.
4. In any text field, press `⌥↑` to start recording and press it again to stop.

The latest release does not yet include the one-line installer. Use the ZIP steps above. If a later release includes the script, follow the [full manual](docs/GUIDE.md#一行指令安裝熟悉終端機).

Already installed? The installer keeps the existing location and settings. To find the app or check the result, see [install location, names and verification](docs/GUIDE.md#安裝位置名稱對照與驗證) (Traditional Chinese).

You can also let an AI agent such as Claude Code or Codex install it: paste the whole prompt from [Let an AI install it](docs/GUIDE.md#直接交給-ai-安裝) (Traditional Chinese).

### Groq API key

Create a key starting with `gsk_` in the [Groq Console](https://console.groq.com/keys) and paste it only into the app's own key window. Please don't use someone else's key. Everyday dictation rarely comes close to the Groq Free Plan limits; see the [English summary of the limits](docs/GUIDE.md#english).

## Privacy

- Audio is sent to the Groq Speech-to-Text API only to be transcribed. The app has no analytics, no ads and no backend of its own.
- Your Groq API key is stored only in this Mac's Keychain, never in a settings file, the repository or a log.
- Clipboard history stays on this Mac and can be paused or cleared at any time. Recordings are not kept as a history.

Details (in Chinese): [PRIVACY.md](PRIVACY.md).

## Documentation

Most documents are written in Traditional Chinese.

| If you want to… | Read |
|---|---|
| Learn every feature and setting | [Full manual](docs/GUIDE.md), [website guide](https://nekonode.cloud/guide) |
| Customise the cat's images and greeting | [CAT-CONFIG.md](CAT-CONFIG.md) |
| Create, share and deliver custom cat packs | [docs/CAT-PACKS.md](docs/CAT-PACKS.md) |
| See what changed in each version | [CHANGELOG.md](CHANGELOG.md), [website changelog](https://nekonode.cloud/changelog) |
| Understand the architecture | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Build from source and run the tests | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md), [docs/TESTING.md](docs/TESTING.md) |
| Understand releases and updates | [docs/UPDATES.md](docs/UPDATES.md) |
| Contribute or report a problem | [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) |

The companion iPhone app is still in development and has not been released.

## License

[MIT License](LICENSE)

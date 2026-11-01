# MVP validation — 2026-10-27

Base: `f2e3e49`. Independent branch `codex/nekochat-windows-lite`. Existing macOS checkout edits preserved; no changes to existing Swift app, Office, VPS configuration, release or production deployment.

## Local evidence (macOS arm64)

- All **27 existing offline script suites** exercised and passed. The initial fresh-checkout run reached `test-updates.sh` without Sparkle tooling and failed its prerequisite check; after `./scripts/fetch-sparkle.sh`, the update suite and the remaining five suites passed. No source change was needed.
- Existing remote protocol suite: passed.
- Existing appearance suite: **1,056 checks passed**, nine coats and existing native renders.
- Existing transcription client suite: passed.
- New C# core: **48 behavior checks passed** (protocol rejection, Unicode limits, endpoint restrictions, nine original JSON appearances, overrides, Groq request/response using a mock HTTP handler).
- New Python Relay: **30 tests passed**, including real TCP WebSocket round-trip/reconnect and actual C# transport ↔ FastAPI delivery/ack (**50** C# checks in that integrated run). No real Groq API call or key used.
- WPF cross-build with .NET 10: passed, zero warnings/errors. This proves compile/XAML generation only, not Windows runtime behavior.
- Native assets generated using original Swift renderer, anatomy and tabby masks. No source artwork edits.

## Windows runner evidence

The first complete [Windows/Linux CI run](https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/actions/runs/40358638121) passed on commit `26da909`: Windows 2025 WPF build, nine native coats/custom-render pixel comparison, bubble/window rendering, Credential Manager write/read/delete, Linux Relay/C# interoperability, and self-contained win-x64 ZIP packaging. Cat/bubble captures were downloaded and visually inspected. Subsequent commits add explicit canceled-input coverage, a chat-window capture, and stricter JSON validation; consult [PR #35 checks](https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/pull/35/checks) for the latest commit and downloadable trial artifacts. CI credentials are temporary fake test values and are removed afterward.

Interactive Windows microphone/focus/DPI/LAN tests are pending. macOS NekoChat App integration is not implemented; the existing macOS app is unchanged. No VPS Relay deployment has been performed.

One local dependency warning: Starlette TestClient deprecates httpx in favor of httpx2; the tested compatibility path still passes. Live WebSocket tests use Uvicorn websockets-sansio.


## One-click classroom follow-up

The one-click addition bundles the existing Python Relay into a standalone executable and embeds the self-contained WPF App plus Relay into a per-user Setup.exe. The App generates two distinct room identities, mutual friend authorization and a private guest invitation; students never type an endpoint/account/friend or edit policy files. The existing manual/VPS mode and v1 WebSocket schema remain available.

Local follow-up baseline: 30 original Relay tests and 48 original C# checks passed. After the addition: 40 Python tests including real bootstrap/parent-EOF shutdown and C# interoperability passed; 92 C# behavior checks passed (94 in live mode), including strict invitations, private-network restrictions, matching-room discovery and installer path/size/required-component guards. WPF and Installer cross-builds pass with zero warnings/errors. The workflow now adds frozen-Relay tests, published-room bidirectional messages and parent shutdown, WPF create/join/leave controls, and single-file setup checksum/extraction after removing external runtimes from PATH. Windows runner results are reported in PR #35; interactive classroom/microphone QA remains pending.

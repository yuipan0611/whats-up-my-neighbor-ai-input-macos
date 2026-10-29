# Windows Lite MVP implementation

Baseline: main `f2e3e49` (2026-10-27). The original macOS checkout has unrelated uncommitted edits; work uses a separate branch and checkout.

## Impact and guardrails

High risk at the new authentication and global text-insertion boundaries. All changes are additive under `nekochat/`, `windows-lite/`, and a new CI workflow. Existing Swift app, Office, VPS desktop, signing, release workflows and credentials remain untouched. No import or dispatch path to Agent/remote-control messages is allowed. Incoming chat is display-only; it can never trigger recording, text insertion or commands.

## Reviewable steps

1. Versioned JSON schema and isolated FastAPI Relay, with auth/authorization/protocol and real socket tests.
2. Transparent draggable WPF cat and chat window using existing artwork/JSON; authenticated LAN/VPS settings and live delivery status.
3. Replaceable STT provider, Credential Manager, explicit global hotkey recording, guarded foreground text insertion and voice-to-chat draft. Add Windows build/package CI and manual QA instructions.

## Visual direction

Use the approved sitting black-cat silhouette at about 180px. Show a bounded plain-text bubble above its head. Clicking the bubble opens the sender's conversation; dragging moves the cat. Right click exposes chat/settings, nine coats, and exit. Connection and recording controls live in a separate normal window. Voice chat always creates an editable draft before Send. No redesign of existing macOS UI.

## Verification

Run existing appearance, remote protocol and transcription suites before changes. Verify Relay schema and authorization with TestClient plus real localhost WebSockets. Compile Windows application with .NET and run platform-independent protocol/provider tests locally; run Windows build and smoke tests on GitHub Actions. Hardware microphone, foreground insertion and visual behavior require interactive Windows QA even if CI passes.

## One-click classroom setup (2026-10-27)

Success: one per-user Setup.exe installs and launches the self-contained WPF app and bundled Relay. No student Python/SDK, shell commands, manual accounts, or JSON edits. First host creates a room; the second computer pastes a private invitation. Groq key remains in Credential Manager. Existing manual LAN/VPS configuration stays available.

Impact: additive Windows installer, in-memory desktop Relay entry point, versioned LAN invitations, WPF room onboarding, packaging/CI/docs. Risk is high at credential provisioning, network binding and installer writes; invitations grant only the paired guest identity, with existing mutual friend authorization. Relay uses only loopback/private IPv4 bindings and shuts down with its owning app. No Agent/remote commands, Swift, Office, VPS or production edits.

Plan: (1) inspectable onboarding preview and existing test baseline; (2) packaged Relay bootstrap + validated invitation/payload extraction with behavioral tests; (3) WPF create/join/leave flow and credential cleanup; (4) self-contained Setup.exe, frozen-Relay and installer integration checks in Windows CI; (5) updated student instructions and PR evidence.

The host explicitly authorizes the guest by privately sharing a high-entropy invitation containing only the guest's room credential. Guest joins with that invitation; neither computer types an account, endpoint or friend ID. The host's token is never included. Room credentials expire when the host process stops; no classroom policy/secret files are written. Public VPS enrollment is outside this addition.

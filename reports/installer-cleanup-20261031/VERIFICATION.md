# macOS installer cleanup — 2026-10-31

Implemented on `codex/installer-cleanup-20261031`, based on `main` at `c68b5d0`.

The shared ZIP/curl installer now serializes replacements at the established installation location. It verifies the source, checks installed identity, stages the new bundle, retains the original until final signature verification and LaunchServices acceptance, then clears the transaction. Copy, replacement, final verification or launch-request failures restore the prior bundle; a failed fresh install removes its own new bundle and login item. Launch acceptance is not a health test of dictation or other app features.

Successful installs also prune completed `.neighbor-update.*` backups containing only one signed product `Previous.app`, older than 24 hours. Symlinks, unknown contents, recent stages, `.installing`, New/Failed bundles and open files remain. File-use checks inspect output as well as status because macOS `lsof` can emit PIDs with exit status 1. Cleanup failures report residual locations without rolling back a committed installation. A forcibly interrupted install can leave a lock/recovery stage; recovery instructions are in the guide.

Sparkle, bundle ID, signing pipeline, user settings and public install entry points are unchanged. The behavior applies to future packages built from this branch; no public release, feed, installed app replacement, main merge or VPS change occurred.

## Verification

- Baseline: reminder tests and 17 release-contract tests passed after restoring checksum-verified pinned Sparkle 2.10.0 tools to this new worktree.
- `./scripts/test-updates.sh`: reminder policy plus 21 release-contract tests passed, including real signed feed/archive tampering and the curl/checksum path.
- Transaction regression coverage: fresh install, same-version reinstall, sequential upgrade; source tampering/identity rejection; copy/replacement/final-verification/launch failures; unchanged profile/login item; first-install rollback.
- Cleanup boundaries: unrelated file/App at destination, symlink target/stage, unknown content, recent and active stages, in-use backup, held install lock, and cleanup failure reporting.
- One-off local maintenance safety fixture passed: enumerated deletion, tracked bundle rejection, in-use/symlink/unknown protection, unchanged installed fixture and Git status. Fixtures used `.noindex` to avoid transient Spotlight indexing handles.
- Shell syntax and `git diff --check` passed. No Swift app code changed; real microphone/UI smoke and a full app rebuild were not required for this installer-only change.

## Local cleanup

Prepared `inventory.json` before removal, with each path, type, logical size, device/inode and content digest. Applied only that inventory, rechecking identity, signature, ownership boundaries, Git tracking, open-file state and digest immediately before each deletion. `cleanup-result.json` records all results; both files stay local and are ignored by Git.

- Removed 21 rebuildable, untracked product App bundles from project/worktree build/dist directories.
- Removed 11 recognized installation backups: seven completed installer stages and four named historical backups.
- Total: 32 entries, 287,993,227 logical bytes (about 275 MiB). This is file-size accounting, not a claim about APFS physical free-space changes.
- No failed or skipped inventory entries during application.
- Before/after digests matched for the running installed App, LaunchAgent, preferences, cat settings and clipboard history. No Keychain contents were exported, and no credential, TCC or user-data deletion commands were run.
- Git status snapshots of all workspace repositories matched across cleanup. Sources, Git, previews, history and report snapshots were retained.
- The existing installed App remains 1.4.9/build 1016 at its established Application Support location, with strict signature verification passing and its original process still running.

## Release follow-up (owner authorized)

The owner subsequently requested PR, green checks, merge to main and public release. Version 1.4.10/build 1017 adds a background post-launch cleanup entry point so Sparkle users receive the same migration, not just ZIP/curl users. The signed `Resources/OldAppCleanup.zsh` is shared with the installer. It validates standard installation location and the current bundle signature, acquires the same install lock, and leaves downloads/previews/worktrees untouched. Background launch retries a held install lock and records only an opt-in success flag. Native Swift-to-shell disposable-profile integration plus installer/feed contract tests pass (22 tests). Public CI and release results will be recorded separately after publication.

# Installer cleanup — impact and verification

- Goal: replace the established installation, retain rollback until validation and launch acceptance, then remove owned backups; clean only enumerated local generated apps and installation backups.
- Owners/consumers: Packaging/安裝.command is bundled by scripts/package-release.sh and invoked by install.sh.template; Tests/test_release_contract.py covers both entry points. Sparkle replacement remains unchanged.
- Protected: running installation, established signing/bundle identity and launch path; Keychain, TCC, preferences, ClipboardHistory, cat settings, raw sources, history/, reports/ and preview apps.
- Risk: high, because cleanup removes files. Restrict to identified owned bundles; reject symlinks and unknown stage contents; serialize installs; inventory local deletion before applying and revalidate each entry.
- Baseline: initial test-updates run passed reminder tests and 16/17 release tests; remaining test required pinned Sparkle tools absent in a new worktree. Reuse and checksum-verify existing archive, then rerun.
- Verification: release-contract regression tests for transaction failure and pruning boundaries; scripts/test-updates.sh; syntax checks; disposable package smoke; local before/after integrity snapshots without reading secrets into logs.

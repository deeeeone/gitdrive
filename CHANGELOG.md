# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `scripts/install.sh` builds and installs GitDrive in one command with a free Apple ID.
- README screenshots.
- File modification dates are stored in `.gitdrive/meta.json` and shown on every Mac. Files added outside GitDrive show the date of the commit GitDrive found them in.

- Folders can be moved between top-level folders. Files are copied to the new repo before the old copy is deleted.

- Optional Git LFS for large files, with a size threshold in Settings. Off by default.

- End-to-end encrypted folders, off by default. Post-quantum X-Wing (ML-KEM-768 + X25519) keys in iCloud Keychain, deduplicated and LZFSE-compressed chunks in Padmé-padded packs, and a sealed index, so GitHub can't see names, layout, file count or sizes. Encrypt new folders automatically or convert existing ones. Needs macOS 26.

### Changed

- Deleting a top-level folder now deletes its GitHub repo. Settings can switch this back to archiving. Sign-in asks for the `delete_repo` scope.

### Fixed

- Open in Finder works from the sandboxed app.
- The drive's trash no longer reports an error to the system.
- Menu icons line up, and empty folders show "Empty" instead of "Zero KB".

## [0.1.0] - 2026-10-13

### Added

- Finder drive built on File Provider, with on-demand downloads and Remove Download.
- One private repo per top-level folder (`drive-<name>`).
- Create, edit, rename, move and delete files and folders, saved as git commits.
- Batched commits, automatic retry when the branch moves, and conflict copies.
- Menu bar app with status, folder sizes, pause, Free Up Space and launch at login.
- Sign-in with GitHub's device flow or a personal access token.
- Add existing repos to the drive and Compact History.

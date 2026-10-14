# Contributing to GitDrive

Thanks for helping out. Bug reports, fixes, docs and features are all welcome.

## Getting set up

1. Follow **Build from source** in the [README](README.md).
2. Create a throwaway private repo named `drive-gitdrive-test` to test against, so you never experiment on real files.

## Project layout

| Path | What's there |
|---|---|
| `Packages/GitDriveCore` | GitHub client, SQLite index and sync engine. Most changes go here. |
| `GitDriveFileProvider` | The File Provider extension. Kept thin. |
| `GitDrive` | The menu bar app (SwiftUI). |
| `docs/` | Architecture notes and README images. |

`GitDrive.xcodeproj` is generated. Edit `project.yml` and run `xcodegen generate` instead of changing the project in Xcode.

## Running the tests

```bash
cd Packages/GitDriveCore
swift test
```

The sync tests run against an in-memory fake of the GitHub API (`Tests/GitDriveCoreTests/FakeGitHub.swift`), so they need no network or token. New sync behaviour should come with a test there.

## Testing the extension

```bash
log stream --predicate 'subsystem == "com.diwan.gitdrive"'
fileproviderctl dump
```

If Finder seems stuck on an old build, quit GitDrive, run `pluginkit -m -v | grep -i gitdrive` to check which copy is registered, and launch the new build again.

## Updating screenshots

Debug builds can show the menu panel in a normal window so it can be captured:

```bash
GITDRIVE_SNAPSHOT=dark build/Build/Products/Debug/GitDrive.app/Contents/MacOS/GitDrive
```

Then capture the window with `screencapture -l <window id>`. Use `light` for the light version.

## Changing settings from the command line

Debug builds accept `GITDRIVE_DEFAULTS` to write shared settings, which are otherwise only reachable from inside the sandbox:

```bash
GITDRIVE_DEFAULTS="lfsEnabled=true,lfsThresholdMB=1" build/Build/Products/Debug/GitDrive.app/Contents/MacOS/GitDrive
```

## Code style

- Swift 6 with strict concurrency. No `@unchecked Sendable` unless a system type forces it, with a comment saying why.
- Keep File Provider callbacks non-blocking and always call their completion handlers.
- Run [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) with the repo's `.swiftformat` before committing.
- Comments explain why, not what.

## Commits and pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org): `feat: ...`, `fix: ...`, `docs: ...`.
- Keep pull requests focused on one change and fill in the template.
- Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for anything users will notice.
- CI must pass.

## Writing style

For docs and UI text: short sentences, plain words, no em dashes, no marketing language.

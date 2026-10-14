# Architecture

GitDrive has three parts:

| Part | Path | Job |
|---|---|---|
| Menu bar app | `GitDrive/` | Sign-in, registers the File Provider domain, polls for changes, shows status and sizes |
| File Provider extension | `GitDriveFileProvider/` | Serves the drive to Finder, receives edits |
| Core package | `Packages/GitDriveCore/` | GitHub client, SQLite index, sync engine. All logic lives here and is unit tested |

The app and the extension share two things: the Keychain access group that holds the token, and the App Group container that holds the SQLite index. Only the extension writes to the index.

## Mapping GitHub onto a drive

- The drive root lists every repo you own whose name starts with `drive-`. `drive-photos` shows up as `photos`.
- A new folder at the root creates a private repo. Renaming it renames the repo. Deleting it deletes the repo, or archives it if that's chosen in Settings.
- Moving a folder between top-level folders copies every file into the other repo and commits there first, then deletes the folder from the original repo in a second commit. If the copy fails, the original is untouched.
- Inside a repo, folders and files map to git trees and blobs on the default branch.
- Git can't store empty folders, so GitDrive writes a hidden `.gitdrive-keep` file into them. Paths under `.gitdrive/` are reserved for GitDrive's own data. Both are hidden from Finder.
- `.DS_Store`, `._*` and `.localized` files stay local and are never committed.

## Modification dates

Git doesn't store file dates, so GitDrive keeps them in `.gitdrive/meta.json`:

```json
{
  "modified" : {
    "notes/todo.md" : "2026-10-14T03:35:00Z"
  },
  "version" : 1
}
```

The file is updated in the same commit as the change it describes, and dates follow files through renames, folder moves and conflict copies. Files added outside GitDrive (on github.com or with `git push`) aren't listed, so they show the date of the newest commit at the time GitDrive saw them change. That is exact for single edits but can be later than the real change if several commits arrived at once. The meta file is read once per new tree and cached by blob SHA.

## Identity and versions

Git has no stable file IDs, so the index gives every item a random ID and keeps it across renames and moves. A rename or move is sent to the sync engine with a *claim*: "path X now belongs to item Y". When the new tree comes back, claimed paths keep their old IDs and everything else is matched by path.

Each item's File Provider version is:

- `contentVersion`: the blob SHA (or `folder`)
- `metadataVersion`: `repo/path`

## Sync anchor

Every insert, update and delete in the index takes the next value of a global sequence number. Deletes leave a tombstone. The File Provider sync anchor is that number, so `enumerateChanges(from:)` is a single query: items and tombstones with a higher sequence.

## Pulling remote changes

1. The app calls `signalEnumerator(for: .workingSet)` every 60 seconds.
2. The extension lists `drive-*` repos and reads each repo's branch head with `If-None-Match`. Unchanged heads cost nothing against the rate limit.
3. For a repo whose head moved, it fetches the full tree (recursive, falling back to walking subtrees when GitHub truncates) and reconciles the index.
4. Finder receives the new and deleted items through the change enumerator.

## Pushing local changes

1. File contents are uploaded as blobs as soon as Finder hands them over.
2. The path-level edit is queued for its repo. While a commit is in flight, new edits wait and are folded into the next commit, so copying a folder of 500 files produces a handful of commits, not 500.
3. A commit is built on the current remote head: create tree, create commit, then update the branch without force.
4. If the branch moved in the meantime, GitDrive refreshes the index and tries again on top of the new head (up to three times).
5. If the file you edited was also changed remotely, the remote version wins at the original path and your version is saved next to it as `name (conflict from Mac YYYY-MM-DD HH.mm).ext`.

Folder moves and deletes are expanded against the real remote tree at commit time, so hidden placeholder files move and delete with their folders.

## Errors

| Cause | Shown in Finder as |
|---|---|
| Token missing, expired or revoked | "Sign in" banner (`notAuthenticated`) |
| Offline, rate limited, GitHub error | Retry later (`serverUnreachable`) |
| File over 100 MB | Upload error with the reason |
| File at the drive root | Error explaining that files go inside folders |

GitHub requests retry with exponential backoff on network failures, 5xx responses and rate limits.

## Debugging

```bash
log stream --predicate 'subsystem == "com.diwan.gitdrive"'
fileproviderctl dump
fileproviderctl evaluate ~/Library/CloudStorage/GitDrive-GitHub/<path>
```

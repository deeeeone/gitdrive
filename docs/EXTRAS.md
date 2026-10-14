# Extras

Optional features live in **Settings → Extras**, each with its own switch, so the core app stays small. Features that cost nothing until you use them are on by default. Anything that changes behaviour, uses GitHub quota or makes something public is off by default.

Many extras are Finder right-click actions. They only appear when the extra is on. Actions that need a window hand off to the GitDrive app, so keep it running in the menu bar.

## Finder

| Extra | Default | What it does |
|---|---|---|
| Sync badges | On | Conflict copies get a warning badge. Upload and download progress are drawn by macOS itself. |
| Quick Look without downloading | On | For plain files over 4 MB, Quick Look and other readers fetch only the byte ranges they need (in 1 MB steps) from `raw.githubusercontent.com`. LFS and encrypted files download in full. |
| Search files that aren't downloaded | On | Finder and Spotlight search ask GitDrive, which answers from its local index. Encrypted names are searchable because they're only ever decrypted into that index on your Mac. Needs macOS 26. |
| Thumbnails without downloading | On | New photos and videos get a 256 px JPEG thumbnail and their EXIF date and location saved alongside. Plain folders keep thumbnails in `.gitdrive/thumbs/`; encrypted folders seal them into their own small packs. Files uploaded before this was on have no thumbnail. |

## History and files

| Extra | Default | What it does |
|---|---|---|
| Show Versions | On | Right-click a file → **Show Versions…** lists every commit that changed it. Open any version, or restore it as a new commit. Works in encrypted folders by reading old index snapshots. |
| Recently Deleted | On | Files deleted in the last 30 days, from the menu bar or a folder's right-click menu, with Restore. |
| Conflict viewer | On | Side-by-side diff for text conflict copies, with Keep Mine, Keep Theirs and Keep Both. Appears in the menu when there are conflicts. |
| Duplicate finder | On | Groups identical files using the hashes the index already has, so nothing downloads. Keep One deletes the others (restorable from Recently Deleted). |
| Monthly bit-rot check | Off | Re-hashes downloaded files (git SHA-1, LFS SHA-256 or the vault content ID) and reports any that changed on disk. |

## Privacy and safety

| Extra | Default | What it does |
|---|---|---|
| Require Touch ID for encrypted folders | Off | Encrypted folders stay locked until you unlock them from the menu with Touch ID or your Mac password. They lock again after the chosen time, when the Mac sleeps, or when the screen locks. Locking removes their decrypted files from Finder. |
| Passcode and decoy folders | Off | A GitDrive passcode unlocks encrypted folders. A second, duress passcode unlocks only the folders you mark as decoys; every other encrypted folder disappears from Finder until the real passcode is used. Hashes are PBKDF2-SHA256 in a Keychain item that stays on this Mac. Wrong guesses slow down after five tries. |
| Ransomware tripwire | On | If 25 overwritten files turn into random-looking data within 10 minutes, GitDrive stops uploading, puts GitHub's copies back on your Mac, holds deletes, and offers **Roll Back the Last Hour**. Normally compressed formats (photos, video, zip, PDF, Office files) never count. |

**How strong the lock is.** Touch ID and the passcode are an access gate enforced by GitDrive's app and extension. The encryption key itself is still in iCloud Keychain, as before. The gate protects against someone using your unlocked Mac; it doesn't protect against malware already running as you. A duress passcode also can't hide that encrypted repos exist on your GitHub account.

**Rolling back** makes a new commit with each folder's earlier contents. Nothing is force-pushed, so the rolled-back changes stay in history too.

## Modes

| Extra | Default | What it does |
|---|---|---|
| Photos | Off | A timeline by EXIF date, a map of geotagged photos and albums by subfolder, for the folders you choose. Browsing uses saved thumbnails; opening a photo downloads it. |
| Notes | Off | Markdown files in chosen folders as a notes app: search, an editor, `[[links]]` (clicking a missing one creates the note) and backlinks. Notes are plain `.md` files. |
| Backups | Off | Mac folders you pick are mirrored once a day (while GitDrive runs) into a top-level folder called "Backup of …". Encrypted if you've set up encryption. Unchanged files are skipped. Git history keeps every earlier version. |

## GitHub

| Extra | Default | What it does |
|---|---|---|
| Publish as website | Off | Right-click a plain folder → **Publish as Website…** copies it to a **public** repo and turns on GitHub Pages. A gallery `index.html` is added if there isn't one. Encrypted folders can't be published. |
| Run in the cloud | Off | Right-click a video → **Compress Video in the Cloud**, or a document → **Convert to PDF in the Cloud**. GitDrive adds `.github/workflows/gitdrive-run.yml` (hidden in Finder) and starts it; ffmpeg or LibreOffice runs on GitHub Actions and commits the result next to the original. Needs the `workflow` token scope and uses Actions minutes. The file path reaches the script only through an environment variable. |
| Open in Codespaces | Off | Right-click a plain folder → **Open in Codespaces** opens its repo in a cloud editor and terminal. |

## Not included

**Time capsule** (timelock encryption with drand) was left out. It needs BLS12-381 pairing cryptography, and there's no Swift library for it. Writing that from scratch would be exactly the kind of untested crypto this project avoids.

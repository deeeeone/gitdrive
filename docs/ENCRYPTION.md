# Encrypted folders

Encryption is off by default. Turn it on in **Settings → Encryption**. It needs macOS 26 or later.

Once it's set up you can encrypt every new top-level folder, or pick existing folders one at a time. An encrypted folder works like any other in Finder, but GitHub only ever stores random-looking data.

## What GitHub can and can't see

| Hidden | Visible |
|---|---|
| Folder name (the repo gets a random name like `drive-2756c1551178`) | That an encrypted GitDrive repo exists |
| File and folder names | Total repo size |
| Folder layout | When you change something |
| Number of files | Roughly how much data each change adds |
| Each file's size | Your public key |
| File contents and dates | |
| Commit messages (always "Update") | |

## Keys

- **Your key pair** is a post-quantum hybrid: ML-KEM-768 (NIST FIPS 203) combined with X25519, as X-Wing. Breaking it would mean breaking both. It's generated once with CryptoKit.
- **The private key** is stored in the Keychain with iCloud Keychain sync, so every Mac on your Apple Account can open your encrypted folders. GitDrive never writes it anywhere else. If iCloud Keychain is off, the key lives only on the Mac that made it.
- **Each encrypted folder** has its own random 256-bit folder key. It's sealed to your public key with HPKE (`XWingMLKEM768X25519_SHA256_AES_GCM_256`) and stored in `.gitdrive/vault.json`, which is the only readable file in the repo.
- Subkeys for chunks, the index, chunk IDs and the chunker come from the folder key through HKDF-SHA256.

If the private key is lost, nobody can decrypt the folders, including you. Never delete the "GitDrive encryption key" item from Keychain Access.

## Repo layout

```
.gitdrive/vault.json     public: your public key and the sealed folder key
.gitdrive/index          sealed: names, folders, sizes, dates, where each chunk lives
p/8e/8e569e68…           sealed packs of chunks, random names
.gitdrive-keep           empty, created with the repo
```

## How files are stored

1. **Chunking.** Files are split with content-defined chunking (FastCDC, 256 KiB to 4 MiB, about 1 MiB on average). The chunker's gear table comes from the folder key, so chunk boundaries can't be used to recognise known files.
2. **Deduplication.** Each chunk's ID is HMAC-SHA256 of its contents under a folder subkey. A chunk that already exists is never stored again, so copies, renames and small edits to big files cost almost nothing.
3. **Compression.** Each chunk is compressed with LZFSE before encryption. Already-compressed data (photos, video, zip files) is stored as it is when compressing saves less than 3%.
4. **Encryption.** Each chunk is sealed with AES-256-GCM using a random nonce, with the chunk ID as associated data. Opening checks the tag and that the plaintext matches its ID, so a swapped or altered chunk is rejected.
5. **Packing.** New chunks from a commit are packed into files of about 8 MiB with random names. Each pack is padded with random bytes using Padmé padding, which reveals at most O(log log n) bits of its true size with under 12% overhead. Packs have no headers, so chunk boundaries inside them aren't visible.
6. **Index.** The index (JSON) is compressed, Padmé-padded, and sealed with AES-256-GCM. It's replaced on every commit.

Packs that no file uses any more are deleted in the next commit. Old versions still sit in the repo's git history until you run **Compact History**.

## Encrypting an existing folder

GitDrive creates a new encrypted repo, copies every file into it (following Git LFS pointers), and then **deletes the readable repo**, including its history. Deleting is the only way to remove readable copies from GitHub, so this needs a token with the `delete_repo` scope. If the delete fails, GitDrive stops and tells you, and both repos stay until you delete the old one yourself.

## Decrypting a folder

**Settings → Encryption → Decrypt…** does the reverse: it creates a normal repo named after the folder, copies every file into it (using Git LFS for large files if that's on), and then deletes the encrypted repo. GitHub can read the folder again afterwards. Characters GitHub doesn't allow in repo names, such as spaces, become `-` in the repo name. Like encrypting, it needs the `delete_repo` scope.

## In Finder

Encrypted top-level folders show a lock badge next to their name. A folder whose key isn't on this Mac shows up as "Locked folder" with nothing inside.

## Why these choices

| Choice | Reason |
|---|---|
| X-Wing (ML-KEM-768 + X25519) | Quantum resistant, and still secure if either half is broken. Built into CryptoKit on macOS 26 |
| AES-256-GCM | Hardware accelerated on Apple Silicon. A 256-bit key stays strong against quantum attacks |
| One key per folder, sealed to your public key | One small header per repo instead of about 1.1 KB per file |
| LZFSE | Built into macOS, no extra library |
| Packs with Padmé padding | Hide file count and sizes, not just names |

## Code

`Packages/GitDriveCore/Sources/GitDriveCore/Vault/` has the chunker, crypto and index. `SyncEngine+Vault.swift` connects them to the sync engine. Tests are in `Tests/GitDriveCoreTests/VaultTests.swift`. They check, among other things, that no name or content appears anywhere in what's uploaded.

# Security policy

## Supported versions

Only the latest release gets security fixes.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's [private vulnerability reporting](https://github.com/deeeeone/gitdrive/security/advisories/new) instead.

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get a reply within 7 days.

## Scope

Things we especially want to hear about:

- The GitHub token leaving the Keychain, appearing in logs, or being sent anywhere other than GitHub
- GitDrive making a repo public, deleting a repo other than through a Finder delete of its top-level folder, or force-pushing without asking
- Files from one user's drive becoming readable by another app or user

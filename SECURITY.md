# Security policy

CleanAppCache deletes files, runs unsandboxed and can ask for administrator
rights. A bug can destroy data. Report problems privately.

## Supported versions

CleanAppCache 0.9 is a public beta available on the [GitHub Releases page](https://github.com/evgeniyov/CleanAppCache/releases/latest).
The maintainer applies security fixes to `master` and includes them in the latest beta release.

## How to report

To report a vulnerability privately on GitHub, open the repository's
**Security** tab and choose **Report a vulnerability**. The maintainer must
enable the feature in the repository settings. If GitHub does not show the
button, open a public issue asking only for a private contact.

Do not describe a vulnerability in a public issue, pull request or discussion.

## What counts

- A way to make the app delete something PathGuard (`Core/PathGuard.swift`)
  should refuse, for example through symlinks, `..`, letter case, Unicode,
  or a race between the path check and deletion.
- A deletion that reaches items outside the selection the user confirmed, or
  a permanent deletion where the interface promised the Trash.
- An administrator force-delete that affects anything other than the offered
  app bundle or can run other commands with elevated rights.
- File names or contents that the app writes outside its local log folder
  `~/Library/Logs/CleanAppCache` or exposes to other users or processes.
- Network access other than the optional external-IP lookup
  (`api.ipify.org`), which is off by default.

The maintainer treats data-loss bugs as security issues even when no attacker
is involved. If the app removed something you did not choose, report it the
same way.

## What to include

- The commit hash or build you used, macOS version and Mac model.
- The screen and exact steps, including the paths involved. You can
  redact personal names, but preserve symlinks, volumes and letter case.
- What was deleted or exposed, and what you expected instead.
- Relevant lines from `~/Library/Logs/CleanAppCache`, if any.
- A proof of concept or a failing test, if you have one.

## What to expect

One maintainer handles reports and will acknowledge and assess yours as soon
as practical. Once the issue is resolved, the maintainer puts the fix on
`master` and records it in `CHANGELOG.md`. The maintainer credits reporters
unless they ask to omit their names. There is no bug bounty.

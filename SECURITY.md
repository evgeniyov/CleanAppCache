# Security Policy

CleanAppCache deletes files, runs unsandboxed and can ask for administrator
rights, so a bug in it can destroy data. Please report problems privately.

## Supported versions

There are no published releases yet. Only the latest commit on `master` is
supported. Once releases exist, fixes will go into the latest release only.

## How to report

Use GitHub's private vulnerability reporting: open the repository's
**Security** tab and choose **Report a vulnerability**. This feature has to be
enabled in the repository settings; if the button is missing, open a public
issue that only asks for a private contact, without any details.

Do not describe a vulnerability in a public issue, pull request or discussion.

## What counts

- A way to make the app delete something PathGuard (`Core/PathGuard.swift`)
  should refuse, for example through symlinks, `..`, case or Unicode tricks,
  or a race between the check and the delete.
- A deletion that reaches items outside the selection the user confirmed, or
  a permanent deletion where the interface promised the Trash.
- The administrator force-delete acting on anything other than the app bundle
  it was offered for, or being usable to run other commands with elevated
  rights.
- Exposure of data the app should not reveal: file names or contents written
  anywhere other than the local log folder `~/Library/Logs/CleanAppCache`,
  or readable by other users or processes.
- Network access other than the optional external-IP lookup
  (`api.ipify.org`), which is off by default.

Data-loss bugs are treated as security issues even when no attacker is
involved. If the app removed something you did not choose, report it the
same way.

## What to include

- The commit hash or build you used, macOS version and Mac model.
- The screen and exact steps, including the paths involved (redact personal
  names if you like, but keep the structure: symlinks, volumes, case).
- What was deleted or exposed, and what you expected instead.
- Relevant lines from `~/Library/Logs/CleanAppCache`, if any.
- A proof of concept or a failing test, if you have one.

## What to expect

This is a single-maintainer project. Reports are handled on a best-effort
basis: an acknowledgement and a first assessment as soon as practical, then a
fix on `master` and a note in `CHANGELOG.md` once the issue is resolved.
Reporters are credited unless they prefer not to be. There is no bug bounty.

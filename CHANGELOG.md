# Changelog

All notable changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Preserve unexpected startup and delayed launch failures in bounded private logs, and clean up workers and forwarded audio sockets on interruption.
- Serialize atomic configuration updates, preserve symlink targets and permissions, and report write failures accurately.
- Require exact entries for removals and prefer exact user-qualified default commands.
- Validate framed remote waypipe version checks, propagate probe application failures, bound post-authentication probes, and detect libpulse from any available candidate.
- Preserve command text across fish and csh login shells, including multiline commands and backslashes.
- Validate installer Bash/SSH requirements, stage copied files, report completion failures, and confine custom-prefix completions.
- Refuse unsafe source-build prefixes and unfamiliar or dirty checkouts, and stage private FFmpeg replacement with rollback.
- Start remote commands on a private D-Bus session when available, so portal file dialogs inherit the launch’s waypipe display.

### Added

- Foreground/verbose launch modes, local doctor diagnostics and an installed version command.
- Isolated concurrency, error, probe, audio-forwarding, diagnostics, installer and build-helper tests, plus Bash 4.4, Alpine and FreeBSD CI jobs.

- Development setup checks, shell syntax CI and contributor instructions for the qargi gitflow workflow.

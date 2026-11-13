# saypipe

Instructions for coding agents and contributors. README.md describes the project and CONTRIBUTING.md describes the gitflow workflow.

## Development environment

- Prerequisites are git, make, POSIX sh and Bash 4.4 or newer. Install missing tools with the system package manager.
- Run `make bootstrap` to check that development tools are available. Preview it with `make -n bootstrap`. These checks need no downloaded dependencies.
- Run `make doctor` before checks and after pulling. It exits nonzero if a required tool is missing.
- Run `make test` at the completed-feature checkpoint. It checks shell syntax, including zsh and fish completions when those shells are installed. It also runs launch-session regression checks with a simulated transport. Remote-host behavior needs separate validation.
- For a task, run the syntax check for each changed shell file.
- Running saypipe requires OpenSSH and waypipe. Audio, GPU and connection-sharing changes need validation with a suitable remote host. Report which paths were exercised.
- Keep install.sh POSIX sh compatible and saypipe compatible with Bash 4.4.

## Workflow

Use feature branches from develop and merge with --no-ff. Master holds tagged releases. Never commit directly to master or develop. Read the relevant qargi skill before running its workflow commands.

User-visible changes get a CHANGELOG.md entry under [Unreleased]. Keep command help, README.md and shell completions consistent when changing the CLI.

.PHONY: bootstrap doctor test

# Development checks need no downloaded dependencies or application installation.
bootstrap: doctor
	@echo "Development tools are ready. See README.md to install saypipe."

doctor:
	@command -v git >/dev/null || { echo "missing: git"; exit 1; }
	@command -v bash >/dev/null || { echo "missing: bash 4.4 or newer"; exit 1; }
	@bash -c '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ))' || { echo "missing: bash 4.4 or newer"; exit 1; }
	@command -v sh >/dev/null || { echo "missing: POSIX sh"; exit 1; }
	@echo "ok: git, bash 4.4 or newer, POSIX sh, make"

test: doctor
	bash -n saypipe
	sh -n install.sh
	bash -n scripts/build-waypipe.sh
	bash -n completions/saypipe.bash
	@if command -v zsh >/dev/null; then zsh -n completions/_saypipe; else echo "skip: zsh completion syntax (zsh unavailable)"; fi
	@if command -v fish >/dev/null; then fish -n completions/saypipe.fish; else echo "skip: fish completion syntax (fish unavailable)"; fi

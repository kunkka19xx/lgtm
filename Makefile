# SPDX-License-Identifier: Apache-2.0
#
# A thin wrapper over `zig build`, which is the build system. This file exists
# for the one thing build.zig should not know: where on *this* machine a binary
# belongs, and what was already there.
#
# The care in `local` and `clean-local` is all about one hazard. A local build is
# not a release: if you already run an lgtm from Homebrew, the AUR or a release
# tarball, `make local` displaces it, and undoing that has to put the real one
# back rather than leave you with nothing. So the previous binary is saved
# before it is overwritten, restored by `clean-local`, and never touched at all
# when something else looks like it owns the path.

PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
DEST := $(BINDIR)/lgtm

# What this Makefile installed, so `clean-local` can tell its own build from a
# release that arrived some other way. Gitignored; safe to delete by hand.
STATE := .make
STAMP := $(STATE)/install-path
SUM := $(STATE)/install-cksum
BACKUP := $(STATE)/backup/lgtm

.DEFAULT_GOAL := help
.PHONY: help local clean-local uninstall test check run clean path path-check

help:
	@echo "make local        build the release binary and install it to $(BINDIR)"
	@echo "make clean-local  remove it, restoring whatever it displaced"
	@echo "make test         unit tests"
	@echo "make check        tests + SPDX headers"
	@echo "make run          run from source, without installing"
	@echo "make path         print the line that puts $(BINDIR) on your PATH"
	@echo "make clean        drop .zig-cache and zig-out; installs are untouched"
	@echo
	@echo "install elsewhere with: make local PREFIX=/usr/local"

# `dist`, not the default build: ReleaseSmall and stripped, which is the binary
# a user would download and the one CI checks against the 1 MB budget.
local:
	zig build dist
	@mkdir -p "$(BINDIR)" "$(STATE)/backup"
	@if [ -L "$(DEST)" ]; then \
		echo "refusing: $(DEST) is a symlink, so something else owns it"; \
		echo "  (Homebrew, nix and stow all install this way, and replacing"; \
		echo "  the link with a file corrupts their bookkeeping)"; \
		echo "  install elsewhere: make local PREFIX=\$$HOME/.local"; \
		exit 1; \
	fi
	@if [ -f "$(STAMP)" ] && [ "$$(cat "$(STAMP)")" != "$(DEST)" ]; then \
		echo "refusing: a local build is already installed at $$(cat "$(STAMP)")"; \
		echo "  run 'make clean-local' first, then install to the new prefix"; \
		exit 1; \
	fi
	@if [ -e "$(DEST)" ] && [ ! -f "$(STAMP)" ]; then \
		cp -p "$(DEST)" "$(BACKUP)"; \
		echo "saved the lgtm already at $(DEST) - 'make clean-local' puts it back"; \
	fi
	@install -m 755 zig-out/bin/lgtm "$(DEST)"
	@printf '%s\n' "$(DEST)" > "$(STAMP)"
	@cksum < "$(DEST)" > "$(SUM)"
	@echo "installed $(DEST) ($$(du -h "$(DEST)" | cut -f1))"
	@$(MAKE) --no-print-directory path-check

# PATH belongs to the shell that ran make, and no child process can change its
# parent's environment - so nothing here, on any OS, can make the shell you are
# standing in find a binary it did not already know about. On macOS this never
# comes up only because something put ~/.local/bin on PATH years ago. These two
# targets are the honest version of that: `path` prints the one line that closes
# the gap, and `path-check` is the advisory `local` prints when it is needed.
#
#     this shell, right now:   eval "$(make -s path)"
#
# To keep it, append that line to your shell's rc file - except on NixOS, where
# .zshrc, .zshenv and .zprofile are all read-only /nix/store symlinks owned by
# home-manager, so `>>` just fails with EACCES. There the same export is spelled
# declaratively, in your home-manager config:
#
#     home.sessionPath = [ "$HOME/.local/bin" ];    # then: home-manager switch
#
# and it lands at the next login, not the next terminal: hm-session-vars.sh
# returns early when __HM_SESS_VARS_SOURCED is already set, so shells spawned
# from the session you are in now keep the old PATH either way.
path:
	@case ":$$PATH:" in *":$(BINDIR):"*) exit 0 ;; esac; \
	if [ "$$(basename "$${SHELL:-sh}")" = fish ]; then \
		echo 'fish_add_path $(BINDIR)'; \
	else \
		echo 'export PATH="$(BINDIR):$$PATH"'; \
	fi

path-check:
	@line=$$($(MAKE) --no-print-directory -s path); \
	if [ -z "$$line" ]; then \
		found=$$(command -v lgtm 2>/dev/null); \
		if [ -n "$$found" ] && [ "$$found" != "$(DEST)" ]; then \
			echo "note: 'lgtm' on PATH is $$found, which comes before $(DEST)"; \
		fi; \
		exit 0; \
	fi; \
	rc=""; \
	case "$$(basename "$${SHELL:-sh}")" in \
		zsh)  rc="$${ZDOTDIR:-$$HOME}/.zshrc" ;; \
		bash) rc="$$HOME/.bashrc" ;; \
		fish) rc="$$HOME/.config/fish/config.fish" ;; \
	esac; \
	nix=""; \
	if [ -n "$$rc" ] && [ -L "$$rc" ]; then \
		case "$$(readlink -f "$$rc" 2>/dev/null)" in /nix/store/*) nix=1 ;; esac; \
	fi; \
	echo; \
	echo "$(BINDIR) is not on your PATH, so 'lgtm' will not be found."; \
	echo "make cannot change the PATH of the shell that ran it. Closest thing:"; \
	echo; \
	echo "  this shell:  eval \"\$$(make -s path)\""; \
	if [ -n "$$nix" ]; then \
		echo "  permanent:   $$rc is a read-only /nix/store symlink, so '>>' fails."; \
		echo "               In your home-manager config instead:"; \
		echo "                 home.sessionPath = [ \"\$$HOME/.local/bin\" ];"; \
		echo "               then 'home-manager switch'. Active at next login."; \
	elif [ -n "$$rc" ]; then \
		echo "  permanent:   make -s path >> $$rc"; \
	else \
		echo "  permanent:   add to your shell's startup file:  $$line"; \
	fi; \
	echo

# The other half of `local`, and named for it: this undoes an install, which is
# a different job from clearing build output and should not happen as a side
# effect of asking for that.
#
# Removes only what `local` put there, and only if it is still that file. A
# release installed over the top since is left alone: deleting someone's
# package-managed binary because a stale stamp said so is the one unrecoverable
# thing this file could do.
clean-local:
	@if [ ! -f "$(STAMP)" ]; then \
		echo "nothing installed by 'make local'"; \
		exit 0; \
	fi; \
	dest=$$(cat "$(STAMP)"); \
	if [ ! -e "$$dest" ]; then \
		echo "$$dest is already gone"; \
	elif [ -f "$(SUM)" ] && ! cksum < "$$dest" | cmp -s - "$(SUM)"; then \
		echo "leaving $$dest alone: it is not the binary 'make local' wrote"; \
		echo "  (a release or package manager has installed over it since)"; \
		rm -rf "$(STATE)"; \
		exit 0; \
	else \
		rm -f "$$dest"; \
		echo "removed $$dest"; \
	fi; \
	if [ -e "$(BACKUP)" ]; then \
		mkdir -p "$$(dirname "$$dest")"; \
		cp -p "$(BACKUP)" "$$dest"; \
		echo "restored the lgtm that was there before"; \
	fi; \
	rm -rf "$(STATE)"

# The spelling the GNU conventions lead people to type.
uninstall: clean-local

test:
	zig build test

check:
	zig build check

run:
	zig build run

# Build output only. An installed binary is not build output, and `clean`
# taking one away is a surprise that costs more than the keystrokes it saves:
# `clean-local` is the target that touches installs.
clean:
	rm -rf .zig-cache zig-out

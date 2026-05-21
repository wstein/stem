# Makefile for workspace-native development and cleanup.
#
# This Makefile provides a normalized interface for native builds, cleanup,
# and notes-path discovery across language ecosystems.
#
# Usage:
#   make          # build the native project (if any)
#   make build    # compile using the native toolchain or no-op
#   make clean    # remove generated output
#   make notes    # show the notes directory path
#
CLEAN_DIR ?= dist

.PHONY: all build clean notes help
all: build

build: ## Build the native project if present; otherwise no-op.
	@echo "No recognized native toolchain found; skipping compile."

clean: ## Remove generated output files.
	rm -rf "$(CLEAN_DIR)"

notes: ## Print the notes directory path.
	@printf "Notes directory: notes\n"

help: ## Show available targets.
	@printf "Available targets:\n  build clean notes\n"

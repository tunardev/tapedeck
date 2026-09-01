# running `make` with no target shows help instead of silently building
.DEFAULT_GOAL := help

.PHONY: help build test fmt fmt-check check run clean

help: ## list available targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "%-12s %s\n", $$1, $$2}'

build: ## zig build
	zig build

test: ## zig build test --summary all
	zig build test --summary all

fmt: ## zig fmt src build.zig tests
	zig fmt src build.zig tests

fmt-check: ## zig fmt --check src build.zig tests
	zig fmt --check src build.zig tests

check: fmt-check test ## fmt-check then test

run: ## zig build run -- ARGS
	zig build run -- $(ARGS)

clean: ## remove build outputs
	rm -rf zig-out .zig-cache .tapedeck-*

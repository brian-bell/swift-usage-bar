# AIUsageBar — build/run targets.
#
# Key gotcha this Makefile guards against: `swift build` only refreshes the
# debug binary under .build; it does NOT rebuild AIUsageBar.app. The app you
# actually run is the bundle, so "see my change" means rebuilding the bundle
# AND relaunching it. `make run` does exactly that.

APP        := AIUsageBar.app
EXECUTABLE := $(APP)/Contents/MacOS/AIUsageBarApp

# Signing identity for the bundle/run targets. A stable self-signed cert (vs.
# ad-hoc) pins the designated requirement to the cert, so Keychain "Always
# Allow" grants survive rebuilds instead of re-prompting. Passed only to the
# targets that sign, so it never leaks into test targets (which exercise
# bundle.sh's own ad-hoc default). Override on the CLI, e.g.
# `make bundle CODESIGN_IDENTITY=-` for an ad-hoc signature.
CODESIGN_IDENTITY ?= AIUsageBar Signing

.DEFAULT_GOAL := help

.PHONY: help build test script-tests bundle verify run stop clean setup-statusline

help: ## List available targets
	@printf 'AIUsageBar targets:\n\n'
	@grep -E '^[a-zA-Z_-]+:.*## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*## "} {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Debug build of the library + app (does NOT build the .app bundle)
	swift build

test: ## Full test harness: build + test build + linkage + UsageCore smoke
	scripts/run-swift-tests

script-tests: ## Run the shell test suites for scripts/
	Tests/Scripts/bundle-script-test.sh
	Tests/Scripts/claude-statusline-cache-test.sh
	Tests/Scripts/setup-statusline-test.sh

bundle: ## Release build → assemble AIUsageBar.app → codesign → verify
	CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" scripts/bundle.sh

verify: ## Verify the existing AIUsageBar.app bundle
	scripts/bundle.sh --verify

run: bundle stop ## Rebuild the bundle, stop any running copy, and launch the fresh one
	open $(APP)
	@printf 'Launched %s (built %s)\n' "$(APP)" "$$(stat -f %Sm $(EXECUTABLE))"

stop: ## Quit any running AIUsageBar instance
	@# Exact process-name match: -f would scan full command lines and could
	@# match this recipe's own /bin/sh (its argv holds the pattern).
	@pkill -x AIUsageBarApp 2>/dev/null && echo 'Stopped running instance' || echo 'No running instance'

clean: ## Remove build artifacts and the app bundle
	rm -rf .build $(APP)

setup-statusline: ## Wire the statusline cache wrapper into Claude Code settings
	scripts/setup-statusline

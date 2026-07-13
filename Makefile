# AIUsageBar — build/run targets.
#
# Key gotcha this Makefile guards against: `swift build` only refreshes the
# debug binary under .build; it does NOT rebuild AIUsageBar.app. The app you
# actually run is the bundle, so "see my change" means rebuilding the bundle
# AND relaunching it. `make run` does exactly that.

APP        := AIUsageBar.app
EXECUTABLE := $(APP)/Contents/MacOS/AIUsageBarApp

# Signing identity for the bundle/run targets. Left empty so bundle.sh
# auto-picks the first Apple Development identity in the keychain — its
# signature carries a genuine TeamIdentifier, so Keychain "Always Allow"
# grants record a stable teamid: partition entry and rebuilds stop
# prompting. Override on the CLI, e.g. `make bundle CODESIGN_IDENTITY=-`
# for an ad-hoc signature.
CODESIGN_IDENTITY ?=

.DEFAULT_GOAL := help

.PHONY: help build test script-tests bundle verify verify-signature run stop clean setup-statusline

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
	@$(MAKE) --no-print-directory verify-signature

verify: ## Verify the existing AIUsageBar.app bundle
	scripts/bundle.sh --verify
	@$(MAKE) --no-print-directory verify-signature

verify-signature: ## Check the bundle carries a stable (non-ad-hoc) signature
	@# Ad-hoc signatures get a fresh cdhash every build, so Keychain "Always
	@# Allow" grants die on rebuild. Treat codesign -dvvv as authoritative.
	@codesign --verify --strict --verbose=2 $(APP)
	@info="$$(codesign -dvvv $(APP) 2>&1)"; \
	printf '%s\n' "$$info" | grep -E '^(Identifier=|Signature|Authority=|TeamIdentifier=)'; \
	if printf '%s\n' "$$info" | grep -q '^Signature=adhoc'; then \
		printf 'FAIL: %s is ad-hoc signed — Keychain grants will not survive rebuilds\n' '$(APP)'; \
		exit 1; \
	fi; \
	if printf '%s\n' "$$info" | grep -q '^TeamIdentifier=not set'; then \
		printf 'note: signed, but no TeamIdentifier (local cert) — Keychain grants pin each build\n'; \
	else \
		printf 'OK: stable signing identity with TeamIdentifier\n'; \
	fi

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

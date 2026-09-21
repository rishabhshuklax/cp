.DEFAULT_GOAL := help
CONFIG ?= release

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build the executable
	swift build -c $(CONFIG)

.PHONY: test
test: ## Run the test suite
	swift test

.PHONY: app
app: ## Assemble build/cp.app
	./Scripts/bundle.sh $(CONFIG)

.PHONY: run
run: app ## Build and launch cp.app
	@# Only ever this bundle's own process: `pkill -x cp` would also kill
	@# whatever /bin/cp happens to be copying a file at the time.
	@pkill -f "build/cp.app/Contents/MacOS/cp" || true
	open build/cp.app

.PHONY: install
install: app ## Copy cp.app to /Applications and launch it
	@pkill -f "cp.app/Contents/MacOS/cp" || true
	rm -rf /Applications/cp.app
	cp -R build/cp.app /Applications/cp.app
	open /Applications/cp.app

.PHONY: uninstall
uninstall: ## Quit cp and remove it from /Applications (your history is kept)
	@pkill -f "cp.app/Contents/MacOS/cp" || true
	rm -rf /Applications/cp.app

.PHONY: icon
icon: ## Redraw Resources/AppIcon.icns from Scripts/make-icon.swift
	swift Scripts/make-icon.swift

.PHONY: clean
clean: ## Remove build artifacts
	rm -rf .build build

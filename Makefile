# Watercoded developer tasks. Run `make help` for a list.
SHELL := /bin/bash
PACKAGE := Packages/WatercodedKit
DERIVED := .build/xcode
CONFIG ?= Debug
INSTALL_DIR ?= /Applications
APP_NAME := $(if $(filter Debug,$(CONFIG)),Watercoded Development,Watercoded)
APP := $(DERIVED)/Build/Products/$(CONFIG)/$(APP_NAME).app

.PHONY: help doctor bootstrap generate build run test lint format icon install clean

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

doctor: ## Check this Mac's setup and explain how to fix problems
	@scripts/doctor.sh

bootstrap: ## Install tooling (Homebrew + Xcode Metal Toolchain), generate the project, then run doctor
	@command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }
	brew bundle --file=Brewfile
	@xcrun metal --version >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain
	$(MAKE) generate
	@scripts/doctor.sh || { echo "Fix the problems above, then run \`make run\`."; exit 1; }

generate: ## Generate Watercoded.xcodeproj from project.yml
	xcodegen generate --use-cache --quiet

build: generate ## Build the app (CONFIG=Debug|Release)
	xcodebuild -project Watercoded.xcodeproj -scheme Watercoded -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' -quiet build

run: build ## Build and launch the app
	open "$(APP)"

install: ## Build Release and install in /Applications (INSTALL_DIR to override)
	$(MAKE) build CONFIG=Release
	@scripts/install.sh "$(DERIVED)/Build/Products/Release/Watercoded.app" "$(INSTALL_DIR)"

test: ## Run the package test suite (Watercoded must be closed)
	@if pgrep -x Watercoded >/dev/null; then \
		echo 'Tests stopped: Watercoded or its background sessions are running. Use an isolated test environment.' >&2; \
		exit 1; \
	fi
	swift test --package-path $(PACKAGE)

lint: ## Check formatting and lint rules
	swiftformat --lint .
	swiftlint lint --strict --quiet

format: ## Format all Swift sources
	swiftformat .
	swiftlint lint --fix --quiet

icon: ## Regenerate the app icon from scripts/generate-app-icon.swift
	swift scripts/generate-app-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset

clean: ## Remove build artifacts and the generated project
	rm -rf .build $(PACKAGE)/.build Watercoded.xcodeproj

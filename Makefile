# Common development commands. The Xcode project is generated from project.yml by XcodeGen.
APP := build/Build/Products/Debug/AgentOS.app

.PHONY: project build run selftest sandbox-test core-test native-test guest-test background-test release-test check engine-check ui-kit clean

project:
	xcodegen generate --quiet

ui-kit:
	cd ui-kit && bun install --frozen-lockfile && bun run build.ts

build: ui-kit project
	xcodebuild -project AgentOS.xcodeproj -scheme AgentOS -configuration Debug -derivedDataPath build -packageAuthorizationProvider netrc build -quiet

run: build
	open $(APP)

# Deterministic kernel/package tests plus real WebKit integration.
core-test:
	swift test

selftest: ui-kit
	swift run RuntimeChecks

sandbox-test: ui-kit
	swift run RuntimeChecks --sandbox tests/fixtures

native-test:
	swift run NativeChecks

background-test: build
	python3 scripts/background-check.py

release-test: ui-kit project
	xcodebuild -project AgentOS.xcodeproj -scheme AgentOS -configuration Release -derivedDataPath build-release -packageAuthorizationProvider netrc build -quiet
	python3 scripts/release-smoke.py
	python3 scripts/background-check.py --configuration Release

guest-test:
	python3 tests/test_oci.py
	python3 -m py_compile vm/guest.py vm/oci.py

check: core-test sandbox-test native-test guest-test engine-check build

engine-check:
	cd agent-engine && bunx tsc -p .

clean:
	rm -rf build AgentOS.xcodeproj agent-engine/dist

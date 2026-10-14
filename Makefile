# Common development commands. The Xcode project is generated from project.yml by XcodeGen.
APP := build/Build/Products/Debug/AgentOS.app

.PHONY: project build run selftest engine-check clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project AgentOS.xcodeproj -scheme AgentOS -configuration Debug -derivedDataPath build build -quiet

run: build
	open $(APP)

# Loads tests/fixtures/snake.html into the runtime, runs a smoke test, writes logs/selftest-result.json.
selftest: build
	$(APP)/Contents/MacOS/AgentOS --selftest-runtime $(CURDIR)/tests/fixtures/snake.html

engine-check:
	cd agent-engine && bunx tsc -p .

clean:
	rm -rf build AgentOS.xcodeproj agent-engine/dist

APP_NAME := OrbitSlim
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
CONFIG ?= release

.PHONY: all build app run install clean cli

all: build

build: app cli

app:
	swift build -c $(CONFIG)
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp ".build/$(CONFIG)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --deep --sign - "$(APP)" 2>/dev/null
	@echo "Built $(APP)"

cli:
	swift build -c $(CONFIG) --product orbitslimctl
	@echo "Built .build/$(CONFIG)/orbitslimctl"

run: app
	open "$(APP)"

install: app
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/$(APP_NAME).app"
	cp -R "$(APP)" "$(HOME)/Applications/$(APP_NAME).app"
	open "$(HOME)/Applications/$(APP_NAME).app"

clean:
	rm -rf .build "$(BUILD_DIR)"

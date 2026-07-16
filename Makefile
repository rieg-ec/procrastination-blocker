APP := ProcrastinationBlocker
HELPER := ProcrastinationBlockerHelper
APP_BIN := .build/release/$(APP)
HELPER_BIN := .build/release/$(HELPER)
BUNDLE := dist/$(APP).app
INSTALL_DIR ?= /Applications

DAEMON_LABEL := com.rieg.procrastination-blocker.enforcer
ROOT_HELPER := /Library/PrivilegedHelperTools/$(DAEMON_LABEL)

.PHONY: build test app install uninstall clean

build:
	swift build -c release

test:
	swift test

app: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Helpers"
	cp packaging/Info.plist "$(BUNDLE)/Contents/Info.plist"
	cp "$(APP_BIN)" "$(BUNDLE)/Contents/MacOS/$(APP)"
	cp "$(HELPER_BIN)" "$(BUNDLE)/Contents/Helpers/$(HELPER)"
	codesign --force --sign - "$(BUNDLE)/Contents/Helpers/$(HELPER)"
	codesign --force --sign - "$(BUNDLE)"
	@echo "built $(BUNDLE)"

install: app
	@pkill -x "$(APP)" 2>/dev/null || true
	sudo mkdir -p "$(INSTALL_DIR)" "/Library/PrivilegedHelperTools"
	sudo rm -rf "$(INSTALL_DIR)/$(APP).app"
	sudo cp -R "$(BUNDLE)" "$(INSTALL_DIR)/"
	sudo chown -R root:wheel "$(INSTALL_DIR)/$(APP).app"
	sudo chmod -R go-w "$(INSTALL_DIR)/$(APP).app"
	sudo install -o root -g wheel -m 0755 "$(HELPER_BIN)" "$(ROOT_HELPER)"
	open "$(INSTALL_DIR)/$(APP).app"
	@echo "installed $(INSTALL_DIR)/$(APP).app and its root-owned session helper"

uninstall:
	-@pkill -x "$(APP)" 2>/dev/null || true
	@if [ ! -x "$(ROOT_HELPER)" ]; then \
		echo "Installed helper is missing; refusing to remove the app before privileged cleanup." >&2; \
		echo "Run make install to restore the helper, then retry make uninstall." >&2; \
		exit 1; \
	fi
	sudo "$(ROOT_HELPER)" uninstall
	sudo rm -rf "$(INSTALL_DIR)/$(APP).app"
	@echo "uninstalled $(APP) and privileged enforcement files"

clean:
	rm -rf .build dist

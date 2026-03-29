APP_NAME := Bandwidther
APP_BUNDLE := $(APP_NAME).app
SWIFT_FILES := BandwidtherApp.swift

.PHONY: all clean

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(SWIFT_FILES) Info.plist AppIcon.icns
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	swiftc -parse-as-library -framework SwiftUI -framework AppKit \
		-o $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) $(SWIFT_FILES)
	cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns

clean:
	rm -rf $(APP_BUNDLE)

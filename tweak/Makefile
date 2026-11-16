# FrameMate SpringBoard notification tweak.
#
# Builds FrameMate.dylib: plain Objective-C against system frameworks, nothing else to link.
# scripts/ios/build-tweak.sh calls `make` here (in a space-free copy) and scripts/ios/package.sh
# wraps the result in a .deb — it does not use `make package`.
#
# Rootless by default (Dopamine / rootless palera1n on iOS 15–16). Override on the command line
# for a rootful jailbreak:  make THEOS_PACKAGE_SCHEME=
THEOS_PACKAGE_SCHEME ?= rootless

# Both slices: SpringBoard is arm64e on A12 and newer (most iOS 16 devices), arm64 on A11.
ARCHS ?= arm64 arm64e
# iOS 16.5 SDK, deployment target 14.0.
TARGET ?= iphone:clang:16.5:14.0

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FrameMate
FrameMate_FILES = Tweak.xm
FrameMate_CFLAGS = -fobjc-arc
# UIKit/CoreGraphics: the app icon. Security: reading the Frame's certificate for the pin check.
FrameMate_FRAMEWORKS = UIKit CoreGraphics Security

include $(THEOS_MAKE_PATH)/tweak.mk

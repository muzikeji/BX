export ARCHS = arm64 arm64e

# iOS 16 and later use the rootless jailbreak layout on supported devices.
TARGET ?= iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= rootless
export TARGET THEOS_PACKAGE_SCHEME

export DEBUG = 0
export FINALPACKAGE = 1

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TypeX

TypeX_FILES = $(wildcard *.x) $(wildcard *.m) $(wildcard *.mm) $(wildcard *.xm)
TypeX_CFLAGS = -fobjc-arc
TypeX_LIBRARIES = sqlite3
TypeX_FRAMEWORKS = UIKit CoreGraphics QuartzCore ImageIO SafariServices PhotosUI UniformTypeIdentifiers JavaScriptCore
TypeX_PRIVATE_FRAMEWORKS = AppSupport Preferences FrontBoardServices SpringBoardServices

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += typexprefs
include $(THEOS_MAKE_PATH)/aggregate.mk

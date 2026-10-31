export ARCHS = arm64 arm64e

# iOS 16 and later use the rootless jailbreak layout on supported devices.
TARGET ?= iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= rootless
export TARGET THEOS_PACKAGE_SCHEME

export DEBUG = 0
export FINALPACKAGE = 1

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MUBX

MUBX_FILES = $(wildcard *.x) $(wildcard *.m) $(wildcard *.mm) $(wildcard *.xm)
MUBX_CFLAGS = -fobjc-arc
MUBX_LIBRARIES = sqlite3
MUBX_FRAMEWORKS = UIKit CoreGraphics QuartzCore ImageIO SafariServices PhotosUI UniformTypeIdentifiers JavaScriptCore
MUBX_PRIVATE_FRAMEWORKS = AppSupport Preferences FrontBoardServices SpringBoardServices

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += mubxprefs
include $(THEOS_MAKE_PATH)/aggregate.mk

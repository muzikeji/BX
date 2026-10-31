ARCHS = arm64 arm64e

TARGET ?= iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = MUBXPrefs

# Vendored AltList (com.opa334.altlist, MIT) — app-list controllers for the
# 生效应用/打开应用 pages; see AltList/README-MUBX-vendor.md.
MUBXPrefs_FILES = $(wildcard *.m) $(wildcard *.mm) $(wildcard AltList/*.m) ../DXPrefsManager.m ../DXShortcutsGenerator.m ../DXHelper.m ../DXAIEngine.m ../DXJavaScriptEngine.m ../DXPanelSystemControlsView.m ../DXPanelPagedGridView.m
MUBXPrefs_INSTALL_PATH = /Library/PreferenceBundles
MUBXPrefs_FRAMEWORKS = UIKit CoreGraphics SwiftUI MobileCoreServices JavaScriptCore UniformTypeIdentifiers
MUBXPrefs_PRIVATE_FRAMEWORKS = Preferences AppSupport
MUBXPrefs_CFLAGS = -fobjc-arc -Wno-tautological-pointer-compare
# Use the build's version override so the header matches the generated DEB.
MUBXPrefs_CFLAGS += -DMUBX_PACKAGE_VERSION=\"$(or $(PACKAGE_VERSION),$(THEOS_PACKAGE_BASE_VERSION))\"
# sparkcolourpicker is no longer needed — using system UIColorPickerViewController
# MUBXPrefs_LIBRARIES = sparkcolourpicker

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp MUBXPrefs.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/MUBXPrefs.plist$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/MUBX$(ECHO_END)
	$(ECHO_NOTHING)chmod 0777 $(THEOS_STAGING_DIR)/Library/MUBX$(ECHO_END)

# iOS 16+ only (matches the package Depends). The old 12.0 target made
# @available() emit __isPlatformVersionAtLeast calls that the rootless link
# cannot resolve.
# SDK is pinned to 16.5: iOS 17 SDKs no longer ship
# PrivateFrameworks/Preferences.framework, so "latest" fails with
# "ld: framework 'Preferences' not found".
TARGET = iphone:clang:16.5:16.0

BUNDLE_NAME = MoreComplications
MoreComplications_FILES = $(wildcard *.m) $(wildcard SkittyPrefs/*.m)
MoreComplications_FRAMEWORKS = UIKit
MoreComplications_PRIVATE_FRAMEWORKS = Preferences
MoreComplications_INSTALL_PATH = /Library/PreferenceBundles
MoreComplications_CFLAGS = -fobjc-arc -Wno-error=deprecated-declarations

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/MoreComplications.plist$(ECHO_END)

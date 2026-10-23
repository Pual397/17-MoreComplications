export ARCHS = arm64 arm64e
# Pin the SDK: iOS 17 SDKs dropped PrivateFrameworks/Preferences.framework, which
# the preferences bundle needs to link. iPhoneOS16.5.sdk still has it.
export TARGET = iphone:clang:16.5:16.0

INSTALL_TARGET_PROCESSES = SpringBoard PosterBoard
SUBPROJECTS = tweak prefs

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

PREFIX = /Applications/Xcode9.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/
TARGET := iphone:clang:8.4:6.0
INSTALL_TARGET_PROCESSES = itunesstored


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FuckOffFairplay8

FuckOffFairplay8_FILES = Tweak.x
FuckOffFairplay8_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

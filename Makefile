TARGET := iphone:clang:latest:15.0
ARCHS = arm64

INSTALL_TARGET_PROCESSES = DespicableMe

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MROffline

MROffline_FILES = Tweak.xm
MROffline_CFLAGS = -fobjc-arc -O2
MROffline_FRAMEWORKS = Foundation UIKit CoreFoundation

# 新版 Theos 的 tweak.mk 默认 INSTALL_PATH 是 /Library/TweakInject，
# 导致 stage 阶段找不到 layout/Library/MobileSubstrate 下的 filter plist。
# 显式指定为传统 Cydia Substrate 目录。
MROffline_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

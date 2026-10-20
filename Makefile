TARGET := iphone:clang:latest:15.0
ARCHS = arm64

# 同时支持有根 / 无根：编译时用 THEOS_PACKAGE_SCHEME=rootless 即可
INSTALL_TARGET_PROCESSES = DespicableMe

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MROffline

MROffline_FILES = Tweak.xm
MROffline_CFLAGS = -fobjc-arc -O2 -Wall
MROffline_FRAMEWORKS = Foundation UIKit CoreFoundation Security

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 DespicableMe || true"

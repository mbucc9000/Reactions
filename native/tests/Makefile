TARGET = iphone:clang:6.1:6.0
ARCHS = armv7
include $(THEOS)/makefiles/common.mk
TOOL_NAME = RXNativeCheck
RXNativeCheck_FILES = main.m ../RXNativeReaction.m ../RXNativeBridge.m
RXNativeCheck_FRAMEWORKS = Foundation
RXNativeCheck_CFLAGS = -fobjc-arc
include $(THEOS_MAKE_PATH)/tool.mk

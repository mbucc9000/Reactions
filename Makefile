TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Reactions ReactionsNative
Reactions_FILES = Tweak.x RXCore.m RXParser.m RXStore.m RXTranscript.m RXBadge.m RXPicker.m RXSend.m RXReply.m native/RXNativeReaction.m native/RXNativeBridge.m
Reactions_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
Reactions_CFLAGS = -fobjc-arc
ReactionsNative_FILES = native/RXNativeDaemon.m native/RXNativeReaction.m native/RXNativeBridge.m
ReactionsNative_FRAMEWORKS = Foundation
ReactionsNative_LIBRARIES = substrate
ReactionsNative_CFLAGS = -fobjc-arc

# The Settings pane is a plain PreferenceLoader plist (layout/Library/PreferenceLoader), no bundle.
include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 MobileSMS"

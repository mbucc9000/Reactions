# SDK 9.3 (GitHub Actions, theos/sdks) apuntando a iOS 6.0. Con el SDK de iOS 6.1 instalado se puede usar:
#   make package TARGET=iphone:clang:6.1:6.0
TARGET ?= iphone:clang:9.3:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Reactions
Reactions_FILES = Tweak.x RXCore.m RXParser.m RXStore.m RXTranscript.m RXBadge.m RXPicker.m RXSend.m RXReply.m
Reactions_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
Reactions_CFLAGS = -fobjc-arc

# The Settings pane is a plain PreferenceLoader plist (layout/Library/PreferenceLoader), no bundle.
include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 MobileSMS"

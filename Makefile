# SDK 9.3 (GitHub Actions, theos/sdks) apuntando a iOS 6.0. Con el SDK de iOS 6.1 instalado se puede usar:
#   make package TARGET=iphone:clang:6.1:6.0
TARGET ?= iphone:clang:9.3:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Reactions ReactionsAgent
Reactions_FILES = Tweak.x RXCore.m RXParser.m RXStore.m RXTranscript.m RXBadge.m RXPicker.m RXSend.m RXReply.m
Reactions_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
Reactions_CFLAGS = -fobjc-arc

# Part that loads into imagent (the daemon that receives and decrypts iMessages). Phase 1A: diagnostics only.
ReactionsAgent_FILES = RXAgent.x
ReactionsAgent_FRAMEWORKS = Foundation CoreFoundation
ReactionsAgent_CFLAGS = -fobjc-arc

# The Settings pane is a plain PreferenceLoader plist (layout/Library/PreferenceLoader), no bundle.
include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 imagent MobileSMS"

<img src="icon.png" width="80" align="right" alt="">

# Reactions

Shows tapback reactions from newer iPhones as badges in iOS 6 Messages, instead of Loved “…” texts. Optional plain-text react and swipe-to-reply.

## Features

- When someone on a newer iPhone reacts to a message, you see a badge on that bubble instead of a text like Loved “hi”.
- Hearts, likes, dislikes, HA HA, !!, ? and emoji reactions, removals, and the newer “Name loved …” texts.
- Optional and off by default: double-tap a bubble to react, or drag it right to reply. These send plain text like Loved “hi”, not real reactions.

## How to use

1. Nothing to set up: reactions people send you show as badges on the bubbles.
2. To react or reply yourself, turn on React & Reply in Settings › Reactions, then double-tap a bubble or drag it right. These send plain text, not real tapbacks.

## Requirements

- Jailbroken iOS 6 (tested on an iPhone 5 with iOS 6.1.2)
- Cydia Substrate and PreferenceLoader (Cydia installs them for you)

## Install

In Cydia, add `https://mbucc9000.github.io/slopkit/` and install **Reactions**. Or download the `.deb` from [Releases](../../releases) and install it with `dpkg -i`.

## Building

[Theos](https://theos.dev) with the iOS 6.1 SDK: `make package FINALPACKAGE=1`.

## License

MIT.

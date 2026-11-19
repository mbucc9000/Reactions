<img src="icon.png" width="80" align="right" alt="">

# Reactions

Native iMessage reactions on iOS 6: see incoming tapbacks as badges, send the six classic reactions to newer iPhones, and show incoming edits in the original bubble.

## Features

- Incoming reactions appear as badges on message bubbles.
- Send hearts, likes, dislikes, laughs, emphasis and questions as native iMessage reactions to newer iPhones.
- Incoming edits update the original bubble with an Edited label.
- React & Reply is off by default. Swipe replies still send ordinary text.

## How to use

1. Incoming reactions show as badges automatically. Show Edits updates matching original bubbles.
2. Enable React & Reply in Settings > Reactions, then double-tap a bubble and choose a reaction. Native sending requires iMessage.
3. Hold a bubble for Copy. Optional swipe replies still arrive as ordinary text, without an inline quote.

## Requirements

- Jailbroken iOS 6 (tested on an iPhone 5 with iOS 6.1.2)
- Cydia Substrate and PreferenceLoader (Cydia installs them for you)

## Install

In Cydia, add `https://mbucc9000.github.io/slopkit/` and install **Reactions**. Or download the `.deb` from [Releases](../../releases) and install it with `dpkg -i`.

## Building

[Theos](https://theos.dev) with the iOS 6.1 SDK: `make package FINALPACKAGE=1`.

## License

MIT.

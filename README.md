<img src="icon.png" width="80" align="right" alt="">

# Reactions

Native iMessage reactions and text replies on iOS 6, with incoming tapback badges and edits in the original bubble.

## Features

- Incoming reactions appear as badges and incoming edits update their original bubbles.
- Double-tap a bubble to send the six classic native iMessage reactions.
- Swipe a bubble right to send a native text reply, with a quote on this iPhone and the newer iPhone.
- Reactions, swipe replies and haptics are enabled by default. Holding a bubble still shows Copy.

## How to use

1. Incoming reactions show as badges. Show Edits updates matching original bubbles.
2. Double-tap a bubble to choose a native iMessage reaction.
3. Swipe a bubble right, type a text reply and send. Native replies require iMessage; attachment replies are not supported yet.
4. Hold a bubble for Copy. Change individual options in Settings > Reactions.

## Requirements

- Jailbroken iOS 6 (tested on an iPhone 5 with iOS 6.1.2)
- Cydia Substrate and PreferenceLoader (Cydia installs them for you)

## Install

In Cydia, add `https://mbucc9000.github.io/slopkit/` and install **Reactions**. Or download the `.deb` from [Releases](../../releases) and install it with `dpkg -i`.

## Building

[Theos](https://theos.dev) with the iOS 6.1 SDK: `make package FINALPACKAGE=1`.

## License

MIT.

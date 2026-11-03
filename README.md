# Telegram-iOS

A third resting point for the interactive back gesture in Telegram for iOS: let go
anywhere mid-swipe and the chat list stays as a narrow column beside the chat,
instead of the gesture being forced to resolve into "back" or "not back".

![Demo](https://raw.githubusercontent.com/Ar2c-Twilight/Tg-ChatSideBar/master/Tg-ChatSideBar-DemoVieo/main.jpg)

*[Watch the 13s demo — 1024 px / 60 fps →](https://github.com/Ar2c-Twilight/Tg-ChatSideBar/releases/download/demo/main.mp4)
(24 MB, MP4)*

Based on upstream `release-12.9.2`
(`6ad963e5b62d354da79040f388ae2b9132fb17b8`) · **[see the full diff →](https://github.com/Ar2c-Twilight/Telegram-iOS/compare/release-12.9.2...chat-sidebar)**
(24 source files, +2696 / −39)

---

## The idea

**One swipe switches the chat, and your finger never has to leave the screen.**

Start the back gesture, stop partway, and the list is already there as a column
beside the chat you were reading. Keep the same finger down, move it vertically,
and the column follows it — the chat behind swaps as you pass each row. Release
when you are on the one you want.

![One gesture, start to finish](https://raw.githubusercontent.com/Ar2c-Twilight/Tg-ChatSideBar/master/Tg-ChatSideBar-DemoVieo/the-idea.gif)

Today that same errand is: finish the swipe, wait for the list, find the row, tap
it, wait for the chat. Four interactions and two full-screen transitions, to do
something the hand had already begun.

None of it needs new geometry. The interactive pop already drives a single scalar —
`NavigationTransitionCoordinator.progress`, 0 when the top controller covers the
screen, 1 when it is gone — and everything the transition draws is a pure function
of that number. A resting point in between is simply a third answer to one question:
*where does this gesture land?*

```swift
public enum NavigationInteractiveDetent {
    case cancel     // back to the top controller — the existing animateCancel path
    case peek       // both controllers on screen: a column of the one below
    case complete   // the pop goes through — the existing animateCompletion path
}
```

Everything else follows from that one addition.

## Prototype

This started outside Telegram. The interaction was designed and tuned in a standalone
UIKit app — no storyboards, no dependencies — and only then carried across:
**[Ar2c-Twilight/Tg-ChatSideBar](https://github.com/Ar2c-Twilight/Tg-ChatSideBar)**

Tuning a gesture means changing a number and feeling the result, over and over. Inside
Telegram-iOS that costs a bazel build per attempt; in a small UIKit app it costs seconds.
So every detent, threshold and spring constant here was settled there first. The demo
above was shot from that prototype.

## Status

Built and run on a physical iPhone 16e, not only in the simulator. The interaction is
complete end to end — all three detents, the vertical takeover, and catching the spring
mid-flight — and holds frame rate on device throughout.

## How it holds together

**Choosing the detent.** `.peek` has to be picked from a finger that is still
moving, so it is judged on position *and* momentum. Position gets a single window
with no hysteresis — the user can see where it is, so there is nothing to flicker.
Momentum is the noisy input, so it gets two thresholds, and revoking the prediction
is deliberately harder than granting it.

**Previewing it.** Once `.peek` is predicted the page on top blurs and shrinks
slightly while the wallpaper behind it grows. Both come off the same number, so
they read as one movement rather than two that coincide.

**Staying catchable.** `NavigationSpringScalar` integrates the landing spring on a
display link rather than using `UIViewPropertyAnimator` or `CASpringAnimation`:
those animate a *property* and hand back only a fraction, while catching a gesture
mid-flight needs the value **and the velocity** at an arbitrary moment. Here that is
`stop()`, which returns both, and the finger continues with no snap.

**Not fighting for the touch.** A parked detent is dismissed by a scroll on the chat
— while that same scroll still has to scroll the chat. `PeekDismissTouchSniffer`
never leaves `.possible`, and a recognizer that never reaches `.began` takes part in
no arbitration: it blocks nothing, and nothing underneath has to be told to fail.

**The column** is 92 pt — `16 + 60 + 16`, the chat row's own avatar inset and
diameter — so the avatar sits centred in it on every device, where a fraction of the
screen width would drift. Two nodes live there: the selection block, and a Saved
Messages shortcut in the strip the title bar and folder tabs vacate.

> The reasoning behind each number — and the measurements it came from — is
> documented inline in the source files listed below.

## The commits

| | |
|---|---|
| [`80f6854`](https://github.com/Ar2c-Twilight/Telegram-iOS/commit/80f685421f) | `build:` inject extra bazel flags via env, ignore local config |
| [`16d4c8b`](https://github.com/Ar2c-Twilight/Telegram-iOS/commit/16d4c8bbd5) | `Display:` interruptible interactive detents for navigation |
| [`9061125`](https://github.com/Ar2c-Twilight/Telegram-iOS/commit/9061125184) | `ChatListUI:` peek column highlight and saved-messages node |
| [`b44c091`](https://github.com/Ar2c-Twilight/Telegram-iOS/commit/b44c0919f6) | Wire sidebar into chat, tab bar and debug settings |

New files:

```
submodules/Display/Source/Navigation/NavigationInteractiveDetent.swift
submodules/Display/Source/Navigation/NavigationSpringScalar.swift
submodules/Display/Source/Navigation/PeekDismissTouchSniffer.swift
submodules/ChatListUI/Sources/Node/ChatListPeekHighlightNode.swift
submodules/ChatListUI/Sources/Node/ChatListPeekSavedMessagesNode.swift
```

## Building

Follow upstream's [build instructions](https://github.com/TelegramMessenger/Telegram-iOS#readme)
first — you need your own `api_id` / `api_hash` from [my.telegram.org](https://my.telegram.org/apps)
in `build-system/<name>-development-configuration.json`. Then:

```bash
xcrun simctl list devices     # find the UDID you want
export TELEGRAM_SIM=<that-udid>
./run.sh                      # build + install + launch on the simulator
./run.sh device               # on a real device (needs TELEGRAM_DEVICE)
```

Two things this fork adds to make a personal-account build work:

- **`TELEGRAM_EXTRA_BAZEL_FLAGS`** — an env hook in `build-system/Make/Make.py`.
  Device builds need `--//Telegram:disableExtensions`, because Xcode-managed signing
  only signs the main app and the analysis phase otherwise fails on `BroadcastUpload`.
- **QR login in `DEBUG`** — upstream's own debug entry point for logging in from
  another device, gated off by `#if DEBUG && false`. Re-enabled here: tap the notice
  text under the phone field.

> ⚠️ Build through `Make.py`, not through Xcode. `rules_xcodeproj` adds flags that make
> `swiftc` crash in MandatoryInlining while deserializing `TelegramCallsUI` SIL vtables
> under the device configuration. The same code builds fine through `Make.py`.

## License

GPLv2, same as upstream Telegram for iOS. The files added by this branch are GPLv2 as well.

# Chat Sidebar

A third resting point for the interactive back gesture in Telegram for iOS: let go
anywhere mid-swipe and the chat list stays as a narrow column beside the chat,
instead of the gesture being forced to resolve into "back" or "not back".

[![Demo video](https://raw.githubusercontent.com/Ar2c-Twilight/Tg-ChatSideBar/master/docs/demo-poster.png)](https://github.com/Ar2c-Twilight/Tg-ChatSideBar/releases/download/demo/main.mp4)

*↑ click for the 13s demo (24 MB, MP4). Shot from the standalone prototype linked below.*

Based on upstream `release-12.9.2`
(`6ad963e5b62d354da79040f388ae2b9132fb17b8`) · **[see the full diff →](https://github.com/Ar2c-Twilight/Telegram-iOS/compare/release-12.9.2...chat-sidebar)**
(24 files, +2693 / −39)

---

## The idea

The interactive pop already drives a single scalar — `NavigationTransitionCoordinator.progress`,
where 0 means the top controller covers the screen and 1 means it is gone. Everything the
transition draws (the top frame, the parallax beneath it, the dim, the edge shadow) is a pure
function of that number.

So a resting point in between needs no new geometry. It needs a third answer to one question:
*where does this gesture land?*

```swift
public enum NavigationInteractiveDetent {
    case cancel     // back to the top controller — the existing animateCancel path
    case peek       // both controllers on screen: a column of the one below
    case complete   // the pop goes through — the existing animateCompletion path
}
```

Everything else follows from that one addition.

## How the decision is made

`.peek` has to be chosen from a finger that is still moving, so it is judged on two criteria at
once — position and momentum:

| | value | why |
|---|---|---|
| `peekWindow` | `0.2 ... 0.8` | A single window, no hysteresis. This is a *position*; the user can see where it is. |
| `momentumEnterThreshold` | `0.4` (≈315 pt/s) | Momentum is the noisy input, so it gets two thresholds. |
| `momentumExitThreshold` | `0.6` (≈470 pt/s) | Revoking the prediction is deliberately harder than granting it — a single threshold makes the decision flicker while a finger hovers near the boundary. |

Once `.peek` is predicted, the transition previews it: the page on top takes a 12pt Gaussian blur
and shrinks to `0.96` while the wallpaper behind it grows. Both come off the same number, so they
read as one movement rather than two that happen to coincide.

## Interruptibility

Catching a spring mid-flight is the whole point, and neither `UIViewPropertyAnimator` nor
`CASpringAnimation` can do it here: both animate a *property* and hand back only a fraction, while
this needs the value **and the velocity** at an arbitrary moment in order to continue from there.

`NavigationSpringScalar` integrates the spring directly on a display link, so taking it over is
just `stop()` — which returns position and velocity together. The finger continues with no snap
and no rebound.

## Dismissing a parked detent

A transition parked at a detent is dismissed by a scroll on the controller on top — while that
same scroll still has to scroll that controller. Two things happening to one finger, not two
gestures competing for it.

`PeekDismissTouchSniffer` therefore never leaves `.possible`. A recognizer that never reaches
`.began` takes part in no arbitration: it blocks nothing, nothing has to be told to fail for it,
and every existing interaction underneath keeps working untouched. It watches and reports.

## The column

`peekColumnWidth` is `92.0`, and it is derived rather than chosen: `16 + 60 + 16`, the chat row's
own avatar inset and diameter. The avatar ends up centred in the column with equal padding on both
sides — a device-independent constraint, where a fraction of the screen width would drift.

Two nodes live there:

- **`ChatListPeekHighlightNode`** — the selection block. Deliberately *not* the per-row highlight
  `ChatListItemNode` already has: that one lives inside a row, so it cannot sit between two rows,
  cannot be split, and cannot outlive the row being recycled. The vertical gesture needs all three.
- **`ChatListPeekSavedMessagesNode`** — a Saved Messages shortcut in the strip the title bar and
  folder tabs vacate when the detent fades them out.

While dragging vertically to pick a chat, the page is only allowed to change below
`peekDragCommitVelocity` (90 pt/s). That threshold is set low on purpose: opening a chat blocks the
main thread for about **90 ms** (measured; median of the stalls during a drag, worst 132 ms), which
at 120 Hz is eleven frames in which nothing moves — not the block, not even touch delivery. Every
switch is expensive enough that it should happen only when the finger has genuinely stopped.

Velocity, not acceleration: a finger sweeping at a steady speed has no acceleration at all, so
acceleration would read the middle of a sweep as "settled" — exactly the rows that must be skipped.

## The commits

| | |
|---|---|
| [`80f6854`](../../commit/80f685421f) | `build:` inject extra bazel flags via env, ignore local config |
| [`16d4c8b`](../../commit/16d4c8bbd5) | `Display:` interruptible interactive detents for navigation |
| [`9061125`](../../commit/9061125184) | `ChatListUI:` peek column highlight and saved-messages node |
| [`b44c091`](../../commit/b44c0919f6) | Wire sidebar into chat, tab bar and debug settings |

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
in `build-system/<name>-development-configuration.json`.

Then:

```bash
xcrun simctl list devices        # find the UDID you want
export TELEGRAM_SIM=<that-udid>
./run.sh                 # build + install + launch on the simulator
./run.sh device          # on a real device (needs TELEGRAM_DEVICE)
```

Two things this fork adds to make a personal-account build work:

- **`TELEGRAM_EXTRA_BAZEL_FLAGS`** — an env hook in `build-system/Make/Make.py` for passing extra
  bazel flags. Device builds need `--//Telegram:disableExtensions`, because Xcode-managed signing
  only signs the main app, and the analysis phase otherwise fails on `BroadcastUpload`.
- **QR login in `DEBUG`** — upstream's own debug entry point for logging in from another device,
  gated off by `#if DEBUG && false`. Re-enabled here: tap the notice text under the phone field.

> ⚠️ Build through `Make.py`, not through Xcode. `rules_xcodeproj` adds
> `--//Telegram:disableStripping` and `--features=-swift.debug_prefix_map`, which make `swiftc`
> crash (signal 6) in MandatoryInlining while deserializing `TelegramCallsUI` SIL vtables under the
> device configuration. The same code builds fine through `Make.py`.

## Also

A standalone UIKit prototype of the same interaction, without the Telegram codebase around it:
**[Ar2c-Twilight/Tg-ChatSideBar](https://github.com/Ar2c-Twilight/Tg-ChatSideBar)**

## License

GPLv2, same as upstream Telegram for iOS. The files added by this branch are GPLv2 as well.

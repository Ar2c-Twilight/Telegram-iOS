#!/bin/bash
# Build + deploy Telegram-iOS. Defaults to the simulator; `./run.sh device` targets a real device.
#
# Machine-specific parameters come from environment variables; the defaults match the author's
# machine, so on another machine you only need to override them:
#   TELEGRAM_SIM        Simulator UDID (find it with `xcrun simctl list devices`)
#   TELEGRAM_DEVICE     Device UDID (find it with `xcrun devicectl list devices`); required for `device`
#   TELEGRAM_CACHE_DIR  Bazel cache directory, defaults to ~/telegram-bazel-cache
set -euo pipefail
cd "$(dirname "$0")"

TARGET="${1:-sim}"
# The simulator can be overridden with a second argument: `./run.sh sim <device-id>`
# ⚠️ The iOS 26.2/26.3.x runtimes have an Apple-confirmed bug: AppleColorEmoji fails to load
# and falls back to LastResort, so every emoji is drawn as a "?" box. Fixed in 26.4, but 26.4
# requires macOS Tahoe 26.2+ and can't be installed on Sequoia. For recording videos, pick an
# iOS 18.x simulator.
SIM="${2:-${TELEGRAM_SIM:-}}"
[ -n "$SIM" ] || { echo "Set TELEGRAM_SIM, or use ./run.sh sim <device-id>"; exit 1; }
DEVICE="${TELEGRAM_DEVICE:-}"                     # xcrun devicectl list devices
# If you keep the cache on an external drive (via a symlink), make sure the drive is mounted first.
#
# When the drive isn't mounted, macOS creates /Volumes/… as a regular directory, so bazel silently
# writes a fresh cache to the internal disk. This project's cache can grow to 120G+, which easily
# fills the disk; the symptom is "No space left on device" midway through the build.
CACHE_DIR="${TELEGRAM_CACHE_DIR:-$HOME/telegram-bazel-cache}"
if [ -L "$CACHE_DIR" ] && [ ! -d "$CACHE_DIR" ]; then
    echo "Cache directory is a dangling symlink: $CACHE_DIR -> $(readlink "$CACHE_DIR")"
    echo "Mount the target, or point TELEGRAM_CACHE_DIR elsewhere (mind the space, it can grow to 120G+)"
    exit 1
fi

MAKE=(python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir "$CACHE_DIR")

if [ "$TARGET" = "sim" ]; then
    # Release rather than debug: frame rate is the whole point, and debug TG is visibly slow
    # (no optimizations, assertions on, every retain/release kept). Stacked on top of the
    # simulator's own overhead, it's unwatchable.
    #
    # ⚠️ dbg and opt are two independent artifact trees in the output base and don't share the
    # action cache, so every switch between them is a full rebuild of ~5900 actions. If you
    # switch, switch once.
    BUNDLE=ph.telegra.Telegraph
    "${MAKE[@]}" build \
        --configurationPath build-system/appstore-configuration.json \
        --codesigningInformationPath build-system/fake-codesigning \
        --buildNumber=1 --configuration=release_sim_arm64

    # Unpack from the .ipa; don't use Telegram_archive-root.
    #
    # archive-root is a Make.py post-processing artifact that isn't regenerated when the build is
    # all cache hits, so it silently installs a stale binary: code changed, build "succeeded",
    # nothing changed on the simulator. The .ipa is the real build output and never goes stale.
    rm -rf .run-unpack && mkdir -p .run-unpack
    unzip -q -o bazel-bin/Telegram/Telegram.ipa -d .run-unpack
    SRC="$PWD/.run-unpack/Payload/Telegram.app"
    # Guard: never rm if SRC didn't resolve, otherwise the simulator ends up with no app at all
    [ -x "$SRC/Telegram" ] || { echo "Freshly built bundle not found: $SRC"; exit 1; }

    xcrun simctl boot "$SIM" 2>/dev/null || true
    xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true

    # get_app_container requires the app to already be installed, so the first install has to go
    # through simctl install.
    DEST="$(xcrun simctl get_app_container "$SIM" "$BUNDLE" app 2>/dev/null || true)"
    if [ -z "$DEST" ]; then
        echo "Not installed on this simulator yet, doing the first install with simctl install"
        xcrun simctl install "$SIM" "$SRC"
    else
        # After that, overwrite the whole bundle: simctl install doesn't replace the app when the
        # build number is unchanged (installd keeps a hard-link cache); the symptom is code changed,
        # build "succeeded", nothing changed on the simulator. The data container lives at a
        # different path, so the login state is unaffected.
        rm -rf "$DEST" && cp -Rp "$SRC" "$DEST"
    fi
    xcrun simctl launch "$SIM" "$BUNDLE"
else
    [ -n "$DEVICE" ] || { echo "Set TELEGRAM_DEVICE (see xcrun devicectl list devices)"; exit 1; }
    CONFIG=build-system/ar2c-development-configuration.json
    BUNDLE="$(python3 -c "import json;print(json.load(open('$CONFIG'))['bundle_id'])")"
    grep -q FILL_ME "$CONFIG" && { echo "$CONFIG still contains FILL_ME; get your api_id/api_hash from https://my.telegram.org/apps first"; exit 1; }

    # Devices default to release: recording videos needs real performance, and debug TG visibly stutters.
    # `./run.sh device debug` switches back to debug (builds a bit faster).
    CONFIGURATION="release_arm64"
    [ "${2:-}" = "debug" ] && CONFIGURATION="debug_arm64"

    # Two things are mandatory; leave out either one and the build fails:
    #
    # 1. --xcodeManagedCodesigning
    #    Uses provisioning profiles generated by Xcode automatic signing. A free personal account
    #    can sign this app: TG's BUILD gates the official entitlements on bundle id, and our bundle
    #    id isn't in official_bundle_ids, so none of iCloud/Siri/Apple Pay/aps get generated. Only
    #    the App Group remains, and personal accounts support App Groups.
    #
    # 2. TELEGRAM_EXTRA_BAZEL_FLAGS=--//Telegram:disableExtensions
    #    Xcode automatic signing only signs the main app, not extensions like BroadcastUpload.
    #    Without disabling extensions, analysis fails with
    #    "no such target BroadcastUpload.mobileprovision". This env var is a hook we added to
    #    Make.py (see extra_bazel_flags in build-system/Make/Make.py); upstream doesn't have it.
    #
    # ⚠️ Don't build through Xcode. rules_xcodeproj additionally injects --//Telegram:disableStripping
    # and --features=-swift.debug_prefix_map, which under the device configuration make swiftc
    # crash (signal 6) while deserializing TelegramCallsUI's SIL vtable during MandatoryInlining.
    # The same code builds fine through make.
    TELEGRAM_EXTRA_BAZEL_FLAGS='--//Telegram:disableExtensions' \
    "${MAKE[@]}" build \
        --configurationPath "$CONFIG" \
        --xcodeManagedCodesigning \
        --buildNumber=1 --configuration="$CONFIGURATION"

    # devicectl takes the .ipa directly, no unpacking needed
    xcrun devicectl device install app --device "$DEVICE" bazel-bin/Telegram/Telegram.ipa
    xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE"
fi

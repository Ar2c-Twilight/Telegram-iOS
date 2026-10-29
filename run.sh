#!/bin/bash
# 构建 + 部署 Telegram-iOS。默认模拟器；`./run.sh device` 走真机。
#
# 机器相关的参数走环境变量，默认值对应作者的机器，换机器只需要覆盖它们：
#   TELEGRAM_SIM        模拟器 UDID（xcrun simctl list devices 查）
#   TELEGRAM_DEVICE     真机 UDID（xcrun devicectl list devices 查），走 device 时必填
#   TELEGRAM_CACHE_DIR  bazel 缓存目录，默认 ~/telegram-bazel-cache
set -euo pipefail
cd "$(dirname "$0")"

TARGET="${1:-sim}"
# 模拟器可以用第二个参数覆盖：`./run.sh sim <device-id>`
# ⚠️ iOS 26.2/26.3.x 的运行时有 Apple 已确认的 bug：AppleColorEmoji 加载失败、
# 回落到 LastResort，于是每个 emoji 都画成「?」方块。26.4 修了，但 26.4 要 macOS
# Tahoe 26.2+，Sequoia 上装不了。要录视频的话挑 iOS 18.x 的模拟器。
SIM="${2:-${TELEGRAM_SIM:-}}"
[ -n "$SIM" ] || { echo "设置 TELEGRAM_SIM，或 ./run.sh sim <device-id>"; exit 1; }
DEVICE="${TELEGRAM_DEVICE:-}"                     # xcrun devicectl list devices
# 如果你把缓存放在外置盘上（软链接过去），先确认盘挂着。
#
# 盘没挂的时候 macOS 会把 /Volumes/… 当普通目录创建出来，于是 bazel 默默地往内置盘
# 里写一份新缓存——这个项目的缓存能涨到 120G+，很容易把盘塞满，症状是构建中途报
# "No space left on device"。
CACHE_DIR="${TELEGRAM_CACHE_DIR:-$HOME/telegram-bazel-cache}"
if [ -L "$CACHE_DIR" ] && [ ! -d "$CACHE_DIR" ]; then
    echo "缓存目录是个悬空软链接：$CACHE_DIR -> $(readlink "$CACHE_DIR")"
    echo "把目标挂上，或者设 TELEGRAM_CACHE_DIR 指到别处（注意容量，能涨到 120G+）"
    exit 1
fi

MAKE=(python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir "$CACHE_DIR")

if [ "$TARGET" = "sim" ]; then
    # release 而不是 debug：要看的就是帧率，而 debug 的 TG 慢得肉眼可见（无优化、带断言、
    # retain/release 全留着），叠在模拟器本来就有的损失上没法看。
    #
    # ⚠️ dbg 和 opt 在 output base 里是两套独立的产物树，action cache 不互通，所以在两者
    # 之间来回切每次都是全量 5900 个动作。要换就一次换过去。
    BUNDLE=ph.telegra.Telegraph
    "${MAKE[@]}" build \
        --configurationPath build-system/appstore-configuration.json \
        --codesigningInformationPath build-system/fake-codesigning \
        --buildNumber=1 --configuration=release_sim_arm64

    # 从 .ipa 解，不要用 Telegram_archive-root。
    #
    # archive-root 是 Make.py 的后处理产物，构建全是缓存命中时它不会重新生成，于是
    # 会悄悄装上一份旧二进制——代码改了、构建「成功」了、模拟器上没变化。
    # .ipa 是真正的构建输出，不会陈旧。
    rm -rf .run-unpack && mkdir -p .run-unpack
    unzip -q -o bazel-bin/Telegram/Telegram.ipa -d .run-unpack
    SRC="$PWD/.run-unpack/Payload/Telegram.app"
    # 守卫：SRC 没解析出来就绝不 rm，否则模拟器上会连 app 都没有
    [ -x "$SRC/Telegram" ] || { echo "新构建的 bundle 不存在: $SRC"; exit 1; }

    xcrun simctl boot "$SIM" 2>/dev/null || true
    xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true

    # get_app_container 要求 App 已经装过，所以首次安装得走 simctl install。
    DEST="$(xcrun simctl get_app_container "$SIM" "$BUNDLE" app 2>/dev/null || true)"
    if [ -z "$DEST" ]; then
        echo "这台模拟器上还没装过，用 simctl install 装第一次"
        xcrun simctl install "$SIM" "$SRC"
    else
        # 之后都整包覆盖：simctl install 在 build number 不变时不会替换
        # （installd 有硬链接缓存），症状是代码改了、构建「成功」了、模拟器上没变化。
        # 数据容器是另一条路径，登录状态不受影响。
        rm -rf "$DEST" && cp -Rp "$SRC" "$DEST"
    fi
    xcrun simctl launch "$SIM" "$BUNDLE"
else
    [ -n "$DEVICE" ] || { echo "设置 TELEGRAM_DEVICE（xcrun devicectl list devices）"; exit 1; }
    CONFIG=build-system/ar2c-development-configuration.json
    BUNDLE="$(python3 -c "import json;print(json.load(open('$CONFIG'))['bundle_id'])")"
    grep -q FILL_ME "$CONFIG" && { echo "$CONFIG 里还有 FILL_ME，先去 https://my.telegram.org/apps 拿 api_id/api_hash"; exit 1; }

    # 真机默认 release：录视频要真实性能，debug 的 TG 肉眼可见地卡。
    # `./run.sh device debug` 可以切回 debug（编得稍快些）。
    CONFIGURATION="release_arm64"
    [ "${2:-}" = "debug" ] && CONFIGURATION="debug_arm64"

    # 两件必须带的事，缺一个就编不出来：
    #
    # 1. --xcodeManagedCodesigning
    #    用 Xcode 自动签名生成的描述文件。免费个人账号能签这个 App——TG 的 BUILD
    #    按 bundle id 门控官方 entitlement，我们的 bundle id 不在 official_bundle_ids
    #    里，所以 iCloud/Siri/Apple Pay/aps 一个都不会生成，最后只剩 App Group，
    #    而 App Group 个人账号是支持的。
    #
    # 2. TELEGRAM_EXTRA_BAZEL_FLAGS=--//Telegram:disableExtensions
    #    Xcode 自动签名只给主 App 签了，没给 BroadcastUpload 之类的扩展签，
    #    不关掉扩展会在分析阶段就报 "no such target BroadcastUpload.mobileprovision"。
    #    这个环境变量是我们给 Make.py 开的口子（见 build-system/Make/Make.py 的
    #    extra_bazel_flags），上游没有。
    #
    # ⚠️ 不要走 Xcode 构建这条路。rules_xcodeproj 会额外塞 --//Telegram:disableStripping
    # 和 --features=-swift.debug_prefix_map，在真机配置下会让 swiftc 在
    # MandatoryInlining 阶段反序列化 TelegramCallsUI 的 SIL vtable 时崩掉（signal 6）。
    # 同样的代码走 make 这条路就没事。
    TELEGRAM_EXTRA_BAZEL_FLAGS='--//Telegram:disableExtensions' \
    "${MAKE[@]}" build \
        --configurationPath "$CONFIG" \
        --xcodeManagedCodesigning \
        --buildNumber=1 --configuration="$CONFIGURATION"

    # devicectl 直接吃 .ipa，不用解包
    xcrun devicectl device install app --device "$DEVICE" bazel-bin/Telegram/Telegram.ipa
    xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE"
fi

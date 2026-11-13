#!/bin/bash
#
# 把 dist/<App>.app 打成可分发的 dmg
#
#   ./build-app.sh          # 正常打包会**自动**调用本脚本（--no-dmg 可跳过）
#   ./tools/make-dmg.sh     # 只重打 dmg，不重新构建（改完图标/壳子时用）
#   ./tools/make-dmg.sh --no-verify  # 跳过签名校验（只在排查时用）
#
# 为什么是独立脚本而不是内联在 build-app.sh 里：
#   单独跑一次不用等 30 秒的 swift build，改 dmg 的外观（卷标、布局）时很方便。
#   但**默认一定要出**：dmg 是唯一对外交付的安装包格式，build-app.sh 在
#   「签名之后、安装之前」调用它，顺序反了就得挂载重签，TCC 授权会跟着失效。
#
# 产物：dist/BoxMouse-<版本>.dmg
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="BoxMouse"
VERSION="$(cat VERSION)"
APP_PATH="dist/${APP_NAME}.app"
OUT_PATH="dist/${APP_NAME}-${VERSION}.dmg"
VERIFY=1

for arg in "$@"; do
    case "$arg" in
        --no-verify) VERIFY=0 ;;
        -h|--help)   sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "未知参数：$arg"; exit 2 ;;
    esac
done

# ---------- 前置检查 ----------
if [[ ! -d "$APP_PATH" ]]; then
    echo "✗ 找不到 ${APP_PATH} —— 先跑 ./build-app.sh"
    exit 1
fi

if [[ "$VERIFY" == "1" ]]; then
    # 签名坏了就别发：用户装上会被 Gatekeeper 拦，而且 TCC 授权也会失效
    if ! codesign --verify --strict "$APP_PATH" 2>/dev/null; then
        echo "✗ 签名校验没过，先修签名再打包"
        exit 1
    fi
    echo "  ✓ 签名校验通过"
fi

# 版本要对得上，免得把 1.0.27 的壳当 1.0.28 发出去
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
                 "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "")"
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
    echo "✗ 包里的版本（${PLIST_VERSION}）与 VERSION（${VERSION}）不一致"
    exit 1
fi
echo "  ✓ 版本一致：${VERSION}"

# ---------- 组装挂载后的样子 ----------
# 临时目录里放「应用本体 + 一个指向 /Applications 的软链」，
# 用户打开 dmg 看到的就是「把它拖过去」这个动作，不用读说明书。
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ditto 而不是 cp -R：保留资源分支、扩展属性与签名封存信息
ditto "$APP_PATH" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"

# ---------- 生成 ----------
rm -f "$OUT_PATH"
echo "  压缩中…"
# UDZO = 只读 + zlib 压缩；HFS+ 为主是为了兼容还没升到 APFS 的机器
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$OUT_PATH" >/dev/null

# ---------- 校验 ----------
if ! hdiutil verify "$OUT_PATH" >/dev/null 2>&1; then
    echo "✗ dmg 校验失败：${OUT_PATH}"
    exit 1
fi
echo "  ✓ dmg 校验通过"

# ---------- 挂起来验货 ----------
# 只校验 dmg 文件本身不够：要确认「dmg 里那个 app」跟刚才验证过的 dist 是同一份。
# cdhash 不一致 = 用户装上的东西跟我们测过的不是一份，TCC 授权也会对不上。
if [[ "$VERIFY" == "1" ]]; then
    MOUNT_POINT="$(mktemp -d)"
    # 用 -nobrowse 免得在 Finder 里弹出窗口；-readonly 防止误写
    hdiutil attach "$OUT_PATH" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
    # shellcheck disable=SC2064
    trap "hdiutil detach '$MOUNT_POINT' >/dev/null 2>&1 || true; rm -rf '$MOUNT_POINT' '$STAGE'" EXIT

    DIST_CDHASH="$(codesign -dvvv "$APP_PATH" 2>&1 | awk -F= '/^CDHash=/ {print $2; exit}')"
    DMG_CDHASH="$(codesign -dvvv "$MOUNT_POINT/${APP_NAME}.app" 2>&1 | awk -F= '/^CDHash=/ {print $2; exit}')"
    if [[ -z "$DIST_CDHASH" || "$DIST_CDHASH" != "$DMG_CDHASH" ]]; then
        echo "  ✗ dmg 里的 app 与 dist 不是同一份签名" >&2
        echo "    dist=${DIST_CDHASH:-?} / dmg=${DMG_CDHASH:-?}" >&2
        exit 1
    fi
    echo "  ✓ dmg 内 app 的 cdhash 与 dist 一致（${DMG_CDHASH}）"

    if [[ ! -L "$MOUNT_POINT/Applications" ]]; then
        echo "  ✗ dmg 里缺少指向 /Applications 的软链，拖拽安装的样式不对" >&2
        exit 1
    fi
    echo "  ✓ 拖拽安装样式完整（BoxMouse.app + Applications 软链）"

    hdiutil detach "$MOUNT_POINT" >/dev/null
    rmdir "$MOUNT_POINT" 2>/dev/null || true
fi

SIZE="$(du -h "$OUT_PATH" | awk '{print $1}')"
echo
echo "────────────────────────────────────────────────────"
echo "dmg 已生成：${OUT_PATH}（${SIZE}）"
echo
echo "挂载后是「${APP_NAME}.app + Applications 软链」的标准拖拽安装样式。"
if [[ "$VERIFY" == "1" ]]; then
    # 这张证书是本机的自签名，不是 Apple Developer ID —— 提示写清楚，
    # 免得下载的人以为是包坏了
    if codesign -d -r- "$APP_PATH" 2>&1 | grep -q "certificate root"; then
        echo
        echo "注意：用的是本机自签名证书，不是 Apple Developer ID。"
        echo "      别人从网上下载后首次打开会被 Gatekeeper 拦，需要"
        echo "      「系统设置 → 隐私与安全性 → 仍要打开」，或右键 → 打开。"
    fi
fi

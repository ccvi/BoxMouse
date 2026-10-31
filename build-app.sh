#!/usr/bin/env bash
#
# ============================================================
# BoxMouse 打包脚本
#
# 产出 dist/BoxMouse.app —— 可双击、可拖进 /Applications 的原生应用。
#
# 用法：
#   ./build-app.sh                发布构建（release，带图标，ad-hoc 签名）
#   ./build-app.sh --debug        调试构建
#   ./build-app.sh --no-sign      跳过签名
#   ./build-app.sh --clean        先清 .build 再构建
#   ./build-app.sh --identity X   用 X 这个代码签名身份签名，代替 ad-hoc
#
# 为什么要 `--identity`：ad-hoc 签名（`--sign -`）每次产物的 cdhash 都变，
# 而「辅助功能」「输入监控」这类 TCC 授权是绑 cdhash 的，等于**每打一次包
# 权限就掉一次**，界面表现就是"手势又没反应了"。换一张固定的本地证书签名，
# 签名要求（leaf = 证书哈希 + bundle id）跨构建稳定，授权就不用反复重开。
# 本机可用身份：security find-identity -v -p codesigning
#
# 版本号：唯一来源是根目录 VERSION。**源码真的变了才 +1**：
#   对影响产物的文件取 sha256 指纹，与 VERSION.fingerprint 比较，
#   不一致就把第三段 +1（1.0.0 → 1.0.1）。反复构建、只改文档不吃版本号。
#   首次打包（没有指纹文件）不递增——1.0.0 是初版，不是"改出来的"。
# ============================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

CONFIGURATION="release"
DO_SIGN=1
SIGN_IDENTITY="-"   # 默认 ad-hoc；--identity 换成固定证书，让 TCC 授权能跨构建保留
DO_INSTALL=0
FORCE_BUMP=0
SKIP_BUMP=0
DO_CLEAN=0
SWIFT_FLAGS=()

for ((i = 1; i <= $#; i++)); do
    argument="${!i}"
    case "$argument" in
        --debug)      CONFIGURATION="debug" ;;
        --no-sign)    DO_SIGN=0 ;;
        --identity)
            if [[ $((i + 1)) -gt $# ]]; then
                echo "--identity 需要一个身份名称（security find-identity -v -p codesigning）" >&2
                exit 1
            fi
            i=$((i + 1))
            SIGN_IDENTITY="${!i}"
            ;;
        --clean)      DO_CLEAN=1 ;;
        --no-sandbox) SWIFT_FLAGS+=(--disable-sandbox) ;;
        --install)    DO_INSTALL=1 ;;
        --bump)       FORCE_BUMP=1 ;;
        --no-bump)    SKIP_BUMP=1 ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "未知参数：${argument}（用 --help 查看用法）" >&2
            exit 1
            ;;
    esac
done

APP_NAME="BoxMouse"
DISPLAY_NAME="BoxMouse"
DIST_DIR="$PROJECT_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

# ------------------------------------------------------------
# 0. 版本号
# ------------------------------------------------------------

VERSION_FILE="$PROJECT_ROOT/VERSION"
FINGERPRINT_FILE="$PROJECT_ROOT/VERSION.fingerprint"

# 参与指纹的文件。不含 dist/（产物）、.build/（中间物）、VERSION*（自指）。
# assets/ 里只有图标母版，tools/ 是确定性渲染脚本，纳入指纹没问题。
SOURCE_INPUTS=(Package.swift build-app.sh Sources Resources tools assets/icon-source.png)

read_version_file() {
    if [[ ! -f "$VERSION_FILE" ]]; then
        echo "错误：缺少 VERSION 文件（应包含一行形如 1.0.0 的版本号）" >&2
        exit 1
    fi
    local value
    value="$(tr -d '[:space:]' < "$VERSION_FILE")"
    if [[ ! "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "错误：VERSION 内容不合法：「${value}」。要求形如 1.0.0（三段数字）。" >&2
        exit 1
    fi
    printf '%s' "$value"
}

bump_patch_version() {
    local major minor patch
    IFS='.' read -r major minor patch <<< "$1"
    printf '%s.%s.%s' "$major" "$minor" "$((patch + 1))"
}

build_number_of() {
    local major minor patch
    IFS='.' read -r major minor patch <<< "$1"
    printf '%s' "$((major * 10000 + minor * 100 + patch))"
}

compute_source_fingerprint() {
    local records=()
    local path entry digest
    for path in ${SOURCE_INPUTS[@]+"${SOURCE_INPUTS[@]}"}; do
        [[ -e "$PROJECT_ROOT/$path" ]] || continue
        if [[ -d "$PROJECT_ROOT/$path" ]]; then
            while IFS= read -r -d '' entry; do
                digest="$(shasum -a 256 "$entry" | awk '{print $1}')"
                records+=("${entry#$PROJECT_ROOT/}:$digest")
            done < <(find "$PROJECT_ROOT/$path" -type f ! -name '.DS_Store' -print0)
        else
            digest="$(shasum -a 256 "$PROJECT_ROOT/$path" | awk '{print $1}')"
            records+=("${path}:$digest")
        fi
    done
    # NUL 分隔 + 排序：与 find 的返回顺序无关
    printf '%s\0' ${records[@]+"${records[@]}"} \
        | LC_ALL=C sort -z \
        | shasum -a 256 | awk '{print $1}'
}

CURRENT_VERSION="$(read_version_file)"
CURRENT_FINGERPRINT="$(compute_source_fingerprint)"

STORED_FINGERPRINT=""
if [[ -f "$FINGERPRINT_FILE" ]]; then
    STORED_FINGERPRINT="$(tr -d '[:space:]' < "$FINGERPRINT_FILE")"
fi

if [[ "$FORCE_BUMP" == "1" ]]; then
    APP_VERSION="$(bump_patch_version "$CURRENT_VERSION")"
    VERSION_REASON="--bump 强制递增"
elif [[ ! -f "$FINGERPRINT_FILE" ]]; then
    APP_VERSION="$CURRENT_VERSION"
    VERSION_REASON="首次打包，沿用 VERSION 里的初版号"
elif [[ "$SKIP_BUMP" == "1" ]]; then
    APP_VERSION="$CURRENT_VERSION"
    VERSION_REASON="--no-bump 保持版本号"
elif [[ "$CURRENT_FINGERPRINT" != "$STORED_FINGERPRINT" ]]; then
    APP_VERSION="$(bump_patch_version "$CURRENT_VERSION")"
    VERSION_REASON="源码有改动"
else
    APP_VERSION="$CURRENT_VERSION"
    VERSION_REASON="源码未变，沿用当前版本"
fi
APP_BUILD_NUMBER="$(build_number_of "$APP_VERSION")"

# 变量一律写成 ${X}：macOS 自带 bash 3.2，`$X` 后紧跟中文会被算进变量名
echo "${DISPLAY_NAME} 打包（${APP_NAME}）"
echo "────────────────────────────────────────────────────"
echo "  版本号：${APP_VERSION}（构建号 ${APP_BUILD_NUMBER}）· ${VERSION_REASON}"
echo "  构建配置：${CONFIGURATION}"
echo "  输出位置：${APP_DIR}"
echo ""

# ------------------------------------------------------------
# 1. 编译
# ------------------------------------------------------------
if [[ "$DO_CLEAN" == "1" ]]; then
    echo "▶ 清理 .build…"
    rm -rf "$PROJECT_ROOT/.build"
fi

echo "▶ 编译（${CONFIGURATION}）…"
swift build -c "$CONFIGURATION" --product "$APP_NAME" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"})/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "错误：没有找到可执行文件 ${BIN_PATH}" >&2
    exit 1
fi
echo "  ✓ 可执行文件：${BIN_PATH}"

# ------------------------------------------------------------
# 2. 自检（打包门禁）
#
# ⚠️ 只跑 .build 下的裸产物，绝不 exec .app 内的二进制
#    （macOS 26 上那样做会让这个 bundle id 的状态栏登记永久失效）。
# ------------------------------------------------------------
echo "▶ 核心自检…"
if "$BIN_PATH" --selftest > /tmp/boxmouse-selftest.log 2>&1; then
    grep -E '^✓' /tmp/boxmouse-selftest.log | sed 's/^/  /' || true
else
    echo "  ✗ 自检未通过，停止打包。完整输出：/tmp/boxmouse-selftest.log" >&2
    tail -20 /tmp/boxmouse-selftest.log | sed 's/^/    /' >&2
    exit 1
fi

# ------------------------------------------------------------
# 3. 图标
#
# 每次都重新渲染：脚本是确定性的（同样的代码产出同样的字节），
# 指纹不会因为"重跑一次"而抖动；反过来"缺了才生成"会让改版过的
# 图标永远进不了包（BoxMusic 踩过）。
# ------------------------------------------------------------
echo "▶ 生成图标…"
# 图标母版是 assets/icon-source.png（由 tools/prepare-icon.py 从原图加工：
# 裁掉四周留白、抠掉白底、按 1024/824 栅格重排）。
# 每次构建都从母版重新出 iconset + icns，不读 dist 里的旧文件——
# 「缺了才生成」会让改过的图标永远进不了包（BoxMusic 踩过）。
ICON_TMP="$(mktemp -d)"
SOURCE_ICON="$PROJECT_ROOT/assets/icon-source.png"

ICON_READY=0
if [[ -f "$SOURCE_ICON" ]]; then
    ICONSET="$ICON_TMP/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$SOURCE_ICON" \
            --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$SOURCE_ICON" \
            --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
    done
    if iconutil -c icns "$ICONSET" -o "$ICON_TMP/AppIcon.icns" 2>/dev/null; then
        ICON_READY=1
    fi
else
    echo "  ⚠ 缺少 assets/icon-source.png" >&2
fi

# ------------------------------------------------------------
# 4. 组装 bundle
# ------------------------------------------------------------
echo "▶ 组装应用包…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
printf 'APPL????' > "$CONTENTS/PkgInfo"

sed -e "s/__BOXMOUSE_VERSION__/$APP_VERSION/g" \
    -e "s/__BOXMOUSE_BUILD__/$APP_BUILD_NUMBER/g" \
    "$PROJECT_ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"

if grep -q '__BOXMOUSE_' "$CONTENTS/Info.plist"; then
    echo "错误：Info.plist 里仍有未替换的占位符，版本注入不完整。" >&2
    exit 1
fi
plutil -lint "$CONTENTS/Info.plist" > /dev/null
echo "  ✓ Info.plist（版本 ${APP_VERSION} · 构建 ${APP_BUILD_NUMBER}）"

if [[ "$ICON_READY" == "1" ]]; then
    cp "$ICON_TMP/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
    echo "  ✓ AppIcon.icns"
else
    echo "  ⚠ 图标生成失败，使用系统默认图标（不影响功能）" >&2
fi
rm -rf "$ICON_TMP"

xattr -cr "$APP_DIR" 2>/dev/null || true

# ------------------------------------------------------------
# 5. 签名
#
# 默认是 ad-hoc（`--sign -`）：不附加受限授权，否则 AMFI 会拒绝启动。
# 但 ad-hoc 的 cdhash 每次构建都变，而「辅助功能」「输入监控」的 TCC 授权
# 是绑定这个哈希的 —— 每打一次包都得重新授权一遍，界面上就是"手势又失效了"。
# `--identity "xxx"` 换成固定证书，签名要求跨构建不变，授权能保留。
# ------------------------------------------------------------
if [[ "$DO_SIGN" == "1" ]]; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        echo "▶ 代码签名（ad-hoc；权限会在下次打包后失效）…"
    else
        echo "▶ 代码签名（身份：${SIGN_IDENTITY}；授权可跨构建保留）…"
    fi
    if codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_DIR" 2>&1 | sed 's/^/  /'; then
        if codesign --verify --deep --strict "$APP_DIR" 2>/dev/null; then
            echo "  ✓ 签名校验通过"
        else
            echo "  ⚠ 签名校验未通过（可用 --no-sign 跳过）" >&2
        fi
    else
        # 身份不存在/失效时退回 ad-hoc，别把包弄坏
        echo "  ⚠ 用「${SIGN_IDENTITY}」签名失败，退回 ad-hoc" >&2
        codesign --force --sign - --timestamp=none "$APP_DIR" 2>&1 | sed 's/^/  /' || true
    fi
else
    echo "▶ 已跳过签名（--no-sign）"
fi

# ------------------------------------------------------------
# 6. 版本号落盘（放在所有可能失败的步骤之后）
# ------------------------------------------------------------
printf '%s\n' "$APP_VERSION" > "$VERSION_FILE"
printf '%s\n' "$CURRENT_FINGERPRINT" > "$FINGERPRINT_FILE"

# ------------------------------------------------------------
# 7. 完成
# ------------------------------------------------------------
echo ""
echo "────────────────────────────────────────────────────"
echo "打包完成：${APP_DIR}"
echo "版本号：${APP_VERSION}（构建号 ${APP_BUILD_NUMBER}）"
echo ""
du -sh "$APP_DIR" | sed 's/^/  体积 /'

if [[ "$DO_INSTALL" == "1" ]]; then
    echo ""
    echo "▶ 安装到 /Applications…"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_DIR" "/Applications/"
    xattr -cr "/Applications/$APP_NAME.app" 2>/dev/null || true
    codesign --force --sign - --timestamp=none "/Applications/$APP_NAME.app" > /dev/null 2>&1 || true
    echo "  ✓ 已安装：/Applications/$APP_NAME.app"
fi

cat <<'TIPS'

首次使用
────────────────────────────────────────────────────
1) 启动
     双击 dist/BoxMouse.app。

2) 授权
     系统会弹「辅助功能」授权引导。没弹就在「权限」页点
     「打开系统设置」，把 BoxMouse 的开关打开，然后重启应用。
     没有这个权限，手势一条都不会触发。

3) 试一条
     打开「手势」页 → 右上角「添加」→ 新建鼠标手势 →
     在轨迹框里按住鼠标画一笔 → 设动作 → 保存。
     然后在屏幕上按住右键画同样的形状。

4) 画错了/没反应
     「手势测试」里能手动画一笔，直接看到与每条手势的相似度，
     不用到系统里去试错。
TIPS

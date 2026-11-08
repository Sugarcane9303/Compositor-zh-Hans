#!/bin/zsh
# ════════════════════════════════════════════════════════════════════════
#  build-dmg.command —— 一键编译「Compositor 汉化版」并打包成 DMG
#
#  用法（任选其一）：
#    1. 在 Finder 里双击本文件（首次可能需要右键 → 打开）
#    2. 打开「终端」，把本文件拖进窗口后回车
#    3. 命令行：zsh build-dmg.command
#
#  它做四件事：
#    1) 检查环境：macOS 26+ / 完整 Xcode 26+ / Apple 芯片
#    2) 编译 Release 版，用本地 ad-hoc 签名（等同 Xcode 的 "Sign to Run Locally"）
#    3) 校验汉化资源确实进了 .app（zh-Hans.lproj + 词条数量）
#    4) 打包成 dist/Compositor-<版本>-zh-Hans.dmg，并挂载验证一次
#
#  不做的事：不签名开发者证书、不公证。产物给自己用没问题；要分发给别人
#  请用项目自带的 scripts/release.sh（需要 Developer ID 证书）。
#
#  可选环境变量：
#    COMPOSITOR_BUILD_DIR   中间产物目录（默认 ~/Library/Caches/CompositorZhHansBuild）
#    COMPOSITOR_NO_OPEN=1   跑完不要在 Finder 里弹出产物
# ════════════════════════════════════════════════════════════════════════

set -eu
set -o pipefail

# ── 输出样式 ─────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else
  B=; G=; Y=; R=; D=; N=
fi
step() { print -r -- ""; print -r -- "${B}==> $*${N}" }
ok()   { print -r -- "${G}  ✓${N} $*" }
warn() { print -r -- "${Y}  !${N} $*" }
info() { print -r -- "${D}    $*${N}" }
die()  { print -r -- ""; print -r -- "${R}  ✗ $*${N}" >&2; exit 1 }

pause() {
  [[ -t 0 ]] || return 0
  print -r -- ""
  read -r "?按回车键关闭此窗口…" _ || true
}

on_exit() {
  local code=$?
  if (( code != 0 )); then
    print -r -- "" >&2
    print -r -- "${R}构建中断（退出码 $code）。${N}" >&2
  fi
  pause
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# ── 定位工程 ─────────────────────────────────────────────────────────────
SCRIPT_PATH="${0:A}"
PROJECT_DIR="${SCRIPT_PATH:h}"
PROJ="$PROJECT_DIR/Compositor.xcodeproj"

print -r -- "${B}Compositor 汉化版 · 本地编译 + DMG 打包${N}"
info "工程目录：$PROJECT_DIR"

[[ -d "$PROJ" ]] || die "没在 $PROJECT_DIR 里找到 Compositor.xcodeproj。
    本脚本必须和 Compositor.xcodeproj 放在同一层目录（压缩包里就是这样）。"

# ── 1. 环境检查 ──────────────────────────────────────────────────────────
step "检查环境"

[[ "$(uname -s)" == "Darwin" ]] || die "这个脚本只能在 macOS 上运行（当前是 $(uname -s)）。"

os_ver=$(sw_vers -productVersion)
os_major=${os_ver%%.*}
if (( os_major < 26 )); then
  die "Compositor 要求 macOS 26 或更高版本，当前是 $os_ver。
    请先升级系统，或在 macOS 26 的机器上编译。"
fi
ok "macOS $os_ver"

arch=$(uname -m)
if [[ "$arch" == "arm64" ]]; then
  ok "Apple 芯片（arm64）"
  DEST="platform=macOS,arch=arm64"
else
  warn "系统架构是 $arch（Intel Mac，或终端跑在 Rosetta 下）。"
  info "Compositor 只支持 Apple 芯片，编译大概率失败。"
  info "如果这台机器其实是 M 系列芯片：关闭终端，取消「使用 Rosetta 打开」后重试。"
  DEST="platform=macOS"
fi

xcode-select -p >/dev/null 2>&1 || die "找不到 Xcode 命令行工具。
    请从 App Store 安装 Xcode 26，然后执行：
    sudo xcode-select -s /Applications/Xcode.app"

developer_dir=$(xcode-select -p)
if [[ "$developer_dir" == *CommandLineTools* ]]; then
  die "当前指向的是 Command Line Tools，不是完整 Xcode（编译 SwiftUI App 需要完整 Xcode）。
    执行这一句修正：
    sudo xcode-select -s /Applications/Xcode.app"
fi

xcodebuild -version >/dev/null 2>&1 || die "xcodebuild 无法运行。
    请先打开一次 Xcode，同意许可协议并等它装完组件。"

xcode_ver=$(xcodebuild -version | awk '/^Xcode/{print $2; exit}')
xcode_major=${xcode_ver%%.*}
ok "Xcode $xcode_ver（$developer_dir）"
if [[ -n "$xcode_major" ]] && (( xcode_major < 26 )); then
  warn "工程用到了 macOS 26 SDK 的新 API，Xcode $xcode_ver 可能编译不过。建议升级到 Xcode 26。"
fi

# Xcode 首次启动组件没装完的话，xcodebuild 会直接报错，先替用户处理
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  warn "Xcode 还没完成首次启动配置，正在尝试自动安装（可能需要输入管理员密码）…"
  sudo xcodebuild -runFirstLaunch || die "Xcode 组件安装失败，请手动打开 Xcode 完成初始化后重试。"
fi

# ── 2. 编译 ──────────────────────────────────────────────────────────────
WORK="${COMPOSITOR_BUILD_DIR:-$HOME/Library/Caches/CompositorZhHansBuild}"
DERIVED="$WORK/DerivedData"
LOG="$WORK/xcodebuild.log"
mkdir -p "$WORK"
rm -rf "$DERIVED"
: > "$LOG"

step "编译 Release 版"
info "首次编译需要联网拉取 Sparkle 依赖，通常 1～5 分钟，请耐心等它跑完。"
info "完整日志：$LOG"
print -r -- ""

# 签名策略：ad-hoc（"-"）+ 空 team —— 和工程 Debug 配置的做法一致，
# 沙盒和 hardened runtime 都照常生效，只在本机有效，不需要任何证书。
build_app() {
  xcodebuild \
    -project "$PROJ" \
    -scheme Compositor \
    -configuration Release \
    -destination "$DEST" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    INFOPLIST_KEY_SUEnableAutomaticChecks=NO \
    build
}

set +e
build_app 2>&1 | tee "$LOG"
build_status=${pipestatus[1]}
set -e

if (( build_status != 0 )); then
  print -r -- ""
  print -r -- "${Y}—— 编译器报的错（最多 25 行）——${N}"
  grep -E "error:|fatal error:|The following build commands failed" "$LOG" | head -25 || true
  die "编译失败。完整日志：$LOG"
fi

APP="$DERIVED/Build/Products/Release/Compositor.app"
[[ -d "$APP" ]] || die "编译报告成功，但没在 $APP 找到产物。日志：$LOG"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || print "1.0")
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist" 2>/dev/null || print "0")
ok "编译完成：Compositor $VERSION ($BUILD_NUM)"

# ── 3. 确认汉化真的进去了 ────────────────────────────────────────────────
step "校验汉化资源"
PLIST="$APP/Contents/Info.plist"

declared=$(plutil -extract CFBundleLocalizations json -o - "$PLIST" 2>/dev/null || print "")
if [[ "$declared" == *zh-Hans* ]]; then
  ok "App 声明了 zh-Hans 本地化"
else
  warn "CFBundleLocalizations 里没看到 zh-Hans —— 中文可能不生效，请检查 Config/Info.plist。"
fi

zh_strings="$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"
if [[ -f "$zh_strings" ]]; then
  count=$(plutil -p "$zh_strings" 2>/dev/null | wc -l | tr -d ' ')
  ok "已打进 $count 条中文词条（zh-Hans.lproj/Localizable.strings）"
else
  warn "包里没有 zh-Hans.lproj/Localizable.strings，界面会显示英文。"
  info "多半是 Compositor/Resources/Localizable.xcstrings 没进 target，请检查工程文件。"
fi

if codesign --verify --strict "$APP" >/dev/null 2>&1; then
  ok "代码签名有效（本地 ad-hoc，仅本机可用）"
else
  warn "签名校验没通过，App 可能起不来。"
fi

autocheck=$(/usr/libexec/PlistBuddy -c "Print :SUEnableAutomaticChecks" "$PLIST" 2>/dev/null || print "true")
case "$autocheck" in
  false|False|NO|No|0) ok "已关闭自动更新检查（不会被上游英文版覆盖）" ;;
  *) warn "自动更新仍是开启状态：上游发新版时可能把汉化版替换成英文原版。"
     info "建议在 App 的「设置」里关掉自动检查更新。" ;;
esac

# ── 4. 打包 DMG ──────────────────────────────────────────────────────────
step "打包 DMG"

STAGE="$WORK/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Compositor.app"
ln -s /Applications "$STAGE/Applications"

DIST="$PROJECT_DIR/dist"
mkdir -p "$DIST"
DMG="$DIST/Compositor-$VERSION-zh-Hans.dmg"
rm -f "$DMG"

volname="Compositor 汉化版 $VERSION"

if command -v create-dmg >/dev/null 2>&1; then
  info "使用 create-dmg（带背景图和应用文件夹快捷方式）"
  # 有 Retina 背景图就合成多分辨率 TIFF，让 DMG 窗口在视网膜屏上也清晰
  typeset -a bg_args
  bg_args=()
  low="$PROJECT_DIR/scripts/dmg/dmg-bg.jpg"
  high="$PROJECT_DIR/scripts/dmg/dmg-bg-retina.jpg"
  if [[ -f "$low" && -f "$high" ]] && command -v tiffutil >/dev/null 2>&1; then
    sips -s format png -s dpiWidth 72  -s dpiHeight 72  "$low"  --out "$WORK/bg.png"    >/dev/null 2>&1 || true
    sips -s format png -s dpiWidth 144 -s dpiHeight 144 "$high" --out "$WORK/bg@2x.png" >/dev/null 2>&1 || true
    if [[ -f "$WORK/bg.png" && -f "$WORK/bg@2x.png" ]] \
      && tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/bg.tiff" >/dev/null 2>&1; then
      bg_args=(--background "$WORK/bg.tiff")
    fi
  fi
  [[ ${#bg_args[@]} -eq 0 && -f "$low" ]] && bg_args=(--background "$low")

  set +e
  create-dmg \
    --volname "$volname" \
    --window-pos 200 120 --window-size 600 380 \
    --icon-size 128 --text-size 13 \
    --icon "Compositor.app" 160 180 --hide-extension "Compositor.app" \
    --app-drop-link 440 180 \
    "${bg_args[@]}" \
    "$DMG" "$STAGE" 2>&1 | sed 's/^/    /'
  dmg_status=${pipestatus[1]}
  set -e
  # create-dmg 在个别系统上会因为 detach 报错返回非 0，只要文件生成了就算成功
  if (( dmg_status != 0 )) && [[ ! -f "$DMG" ]]; then
    warn "create-dmg 失败，改用系统自带 hdiutil"
  fi
fi

if [[ ! -f "$DMG" ]]; then
  info "使用系统自带 hdiutil（无背景图，功能一致）"
  hdiutil create \
    -volname "$volname" \
    -srcfolder "$STAGE" \
    -format UDZO -ov -quiet \
    "$DMG" || die "hdiutil 打包 DMG 失败。"
fi

[[ -f "$DMG" ]] || die "DMG 没生成出来。"

# 挂载验证一次：确认能打开、里面有 App 和「应用程序」快捷方式
step "校验 DMG"
attach_out=$(hdiutil attach "$DMG" -nobrowse -readonly 2>/dev/null || true)
mount_point=$(print -r -- "$attach_out" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
if [[ -n "$mount_point" && -d "$mount_point/Compositor.app" ]]; then
  ok "DMG 可正常挂载，内含 Compositor.app"
  [[ -L "$mount_point/Applications" ]] && ok "含「应用程序」拖放快捷方式"
else
  warn "DMG 挂载后没找到 App，可能有问题。"
fi
[[ -n "$mount_point" ]] && hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || true

# ── 完成 ────────────────────────────────────────────────────────────────
size=$(du -h "$DMG" | awk '{print $1}' | tr -d ' ')
step "完成"
print -r -- "  ${G}$DMG${N}"
print -r -- "  ${D}大小 $size · Compositor $VERSION ($BUILD_NUM) · 简体中文${N}"
print -r -- ""
print -r -- "  装上用：双击 DMG，把 Compositor 拖进「应用程序」。"
print -r -- "  签名是本地的，换台 Mac 首次打开会被 Gatekeeper 拦，右键 → 打开即可。"
print -r -- "  中间产物在 $WORK（想省磁盘可以整个删掉）。"

if [[ -z "${COMPOSITOR_NO_OPEN:-}" ]]; then
  open -R "$DMG" >/dev/null 2>&1 || true
fi

if [[ -t 0 ]]; then
  print -r -- ""
  read -r "?要不要现在试运行刚编译好的 App？(y/N) " answer || answer=""
  if [[ "$answer" == [yY]* ]]; then
    open "$APP"
  fi
fi

exit 0

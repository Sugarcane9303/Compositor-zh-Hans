#!/bin/zsh
# ════════════════════════════════════════════════════════════════════════
#  push-to-github.command —— 把这份汉化源码一次性推到你的 GitHub 仓库
#
#  用法：在这个文件夹里双击（文件夹 = 含 Compositor.xcodeproj 的那一层），
#        按提示粘贴仓库地址即可。已经推过的话，再跑一次就是增量更新。
#
#  需要：git（macOS 自带）。装了 gh 并 gh auth login 过的话体验最好，
#        没有 gh 也能用，只是第一次 push 会让你输用户名 + PAT。
#        PAT 在 https://github.com/settings/tokens 生成，勾 repo 权限。
# ════════════════════════════════════════════════════════════════════════

set -eu

B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
step() { print -r -- ""; print -r -- "${B}==> $*${N}" }
ok()   { print -r -- "${G}  ✓${N} $*" }
warn() { print -r -- "${Y}  !${N} $*" }
die()  { print -r -- ""; print -r -- "${R}  ✗ $*${N}" >&2; exit 1 }

pause() { [[ -t 0 ]] && { print -r -- ""; read -r "?按回车键关闭此窗口…" _ || true } }
trap 'code=$?; (( code != 0 )) && print -r -- "\n${R}推送中断（退出码 $code）。${N}" >&2; pause' EXIT

HERE="${0:A:h}"
cd "$HERE"

print -r -- "${B}把 Compositor 汉化源码推到 GitHub${N}"

[[ -d Compositor.xcodeproj ]] || die "这里没有 Compositor.xcodeproj。
    请先解压交付包，进入 Compositor/ 目录（含 xcodeproj 的那一层）再运行本脚本。"

command -v git >/dev/null || die "没找到 git。执行 xcode-select --install 装一下。"

# ── 1. 仓库地址 ──────────────────────────────────────────────────────────
step "仓库地址"
print -r -- "  形如 ${D}https://github.com/你的名字/Compositor-zh-Hans.git${N}"
print -r -- "  （仓库先在 github.com/new 建好，空仓库，别勾 README）"
print -r -- ""
read -r "?粘贴仓库地址: " REPO
[[ -n "${REPO:-}" ]] || die "没填地址。"

# 顺手容错：允许只填 github.com/xxx/yyy 或 xxx/yyy
case "$REPO" in
  http*) ;;
  github.com/*) REPO="https://${REPO}" ;;
  */*) REPO="https://github.com/${REPO}" ;;
esac
[[ "$REPO" == *.git ]] || REPO="${REPO}.git"
ok "$REPO"

# ── 2. git 仓库与身份 ────────────────────────────────────────────────────
step "准备本地仓库"
if [[ -d .git ]]; then
  ok "已有 .git，沿用"
else
  git init -q -b main
  ok "git init（main 分支）"
fi

if ! git config user.email >/dev/null 2>&1; then
  # 没配置过身份时 commit 会失败，就地补一个
  git config user.name "${USER:-Compositor}"
  git config user.email "${USER:-compositor}@localhost"
  warn "本机没配 git 身份，临时用了 ${USER:-compositor}（只影响这次提交的作者信息）"
fi

# ── 3. 暂存并提交 ────────────────────────────────────────────────────────
step "提交"
git add -A
if git diff --cached --quiet; then
  ok "没有新改动，跳过 commit"
else
  FILES=$(git diff --cached --name-only | wc -l | tr -d ' ')
  git commit -q -m "Compositor 简体中文汉化（基于上游 3e81af3）" \
                 -m "1487 条 String Catalog 条目 + 代码层本地化修复，详见 README。"
  ok "提交了 $FILES 个文件"
fi

# ── 4. 推送 ──────────────────────────────────────────────────────────────
step "推送"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REPO"
else
  git remote add origin "$REPO"
fi

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh auth setup-git
  ok "用 gh 的凭据推送"
else
  warn "没检测到已登录的 gh，push 时终端会问用户名和密码"
  print -r -- "    ${D}密码栏请填 PAT（github.com/settings/tokens，勾 repo），不是账号密码${N}"
fi

if ! git push -u origin main 2>/tmp/push-error.txt; then
  if grep -qi "rejected\|non-fast-forward" /tmp/push-error.txt; then
    warn "远端已有提交（建仓库时勾了 README？），用 --force 覆盖成这份源码"
    read -r "?确认覆盖远端 main 分支？(y/N) " ans
    [[ "$ans" == [yY]* ]] || die "已取消。"
    git push -u origin main --force || die "推送失败，见上面的输出。"
  else
    print -r -- ""
    sed 's/^/    /' /tmp/push-error.txt
    die "推送失败。多半是认证问题：装个 gh（brew install gh && gh auth login）再跑一次最省事。"
  fi
fi

step "完成"
print -r -- "  ${G}${REPO%.git}${N}"
print -r -- ""
print -r -- "  下一步：仓库 Actions 标签 → Build zh-Hans DMG → Run workflow"
print -r -- "  跑完在运行页底部 Artifacts 里下载 DMG。"
exit 0

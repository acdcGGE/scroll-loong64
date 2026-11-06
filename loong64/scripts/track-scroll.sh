#!/usr/bin/env bash
#
# track-scroll.sh — 追踪 scroll 上游更新，并重编重打包为独立 deb
# 平台：Deepin 25 / loong64 (LoongArch)；scroll 是纯 C 项目，系统 gcc 即可
#
# 子命令：
#   check    拉取上游、报告当前/上游 commit 与新提交数（不改任何文件，安全）
#   update   将源码切到上游最新（detached HEAD，强制覆盖本地改动）
#   rebuild  重编 + 重新打包 scroll deb
#   sync     update + rebuild 一步到位
#
# 默认（无参数）等同 check。
#
# 所有路径都可用环境变量覆盖，便于换机复用：
#   BUILD_ROOT     构建根目录             默认 $HOME/build
#   SCROLL_DIR     scroll 源码目录        默认 $BUILD_ROOT/scroll
#   DEB_OUT        deb 输出 / 暂存目录    默认 $BUILD_ROOT/deb
#   SCROLL_REMOTE  追踪的远端名           默认 origin（想直连上游可设 upstream）
#   SCROLL_BRANCH  上游分支名             默认 master（scroll 上游不是 main）
#   BUILD_REV      本地修订号             默认 1（换 hash 后从 1 重新计）
#
set -euo pipefail

# ---------------- 配置 ----------------
BUILD_ROOT=${BUILD_ROOT:-"$HOME/build"}
SCROLL_DIR=${SCROLL_DIR:-"$BUILD_ROOT/scroll"}
DEB_OUT=${DEB_OUT:-"$BUILD_ROOT/deb"}
SCROLL_REMOTE=${SCROLL_REMOTE:-origin}
SCROLL_BRANCH=${SCROLL_BRANCH:-master}
BUILD_REV=${BUILD_REV:-1}

# ---------------- 颜色 ----------------
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_RST=$'\033[0m'
else C_R=; C_G=; C_Y=; C_B=; C_RST=; fi
info(){ echo "${C_B}[*]${C_RST} $*"; }
ok(){ echo "${C_G}[+]${C_RST} $*"; }
warn(){ echo "${C_Y}[!]${C_RST} $*"; }
err(){ echo "${C_R}[x]${C_RST} $*" >&2; }

# ---------------- 前置检查 ----------------
check_prereqs(){
  local miss=0
  for cmd in meson ninja dpkg-deb dpkg-shlibdeps git; do
    command -v "$cmd" >/dev/null 2>&1 || { err "缺少命令: $cmd"; miss=1; }
  done
  [ -d "$SCROLL_DIR/.git" ] || { err "源码目录不存在或不是 git 仓库: $SCROLL_DIR"; miss=1; }
  [ -f "$SCROLL_DIR/meson.build" ] || { err "缺少 meson.build: $SCROLL_DIR"; miss=1; }
  [ "$miss" -eq 0 ] || { err "前置检查未通过，先按 docs/scroll-build.md §1 装好系统依赖"; return 1; }
  ok "前置检查通过"
}

# ---------------- check ----------------
cmd_check(){
  info "检查 scroll ($SCROLL_REMOTE/$SCROLL_BRANCH)"
  git -C "$SCROLL_DIR" fetch -q "$SCROLL_REMOTE" 2>/dev/null \
    || warn "fetch 失败（可能离线，沿用旧数据）"
  local cur up count
  cur=$(git -C "$SCROLL_DIR" rev-parse --short=8 HEAD)
  up=$(git -C "$SCROLL_DIR" rev-parse --short=8 "$SCROLL_REMOTE/$SCROLL_BRANCH" 2>/dev/null || echo "??")
  count=$(git -C "$SCROLL_DIR" rev-list --count "HEAD..$SCROLL_REMOTE/$SCROLL_BRANCH" 2>/dev/null || echo "?")
  echo "  scroll: cur=$cur  upstream=$up  new_commits=$count"
  if [ "$count" != "?" ] && [ "$count" -gt 0 ] 2>/dev/null; then
    warn "有 $count 个新提交（建议版本 0.0~scroll.$up-$BUILD_REV）"
    git -C "$SCROLL_DIR" log --oneline -8 "HEAD..$SCROLL_REMOTE/$SCROLL_BRANCH" | sed 's/^/      /'
  elif [ "$count" = "?" ]; then
    warn "无法比较（远端或分支不存在？检查 SCROLL_REMOTE / SCROLL_BRANCH）"
  else
    ok "已是最新（cur=$cur）"
  fi
}

# ---------------- update ----------------
cmd_update(){
  info "切到 $SCROLL_REMOTE/$SCROLL_BRANCH 最新（detached HEAD，强制覆盖本地改动）"
  git -C "$SCROLL_DIR" checkout -f -q "$SCROLL_REMOTE/$SCROLL_BRANCH"
  cmd_check
}

# ---------------- rebuild ----------------
cmd_rebuild(){
  check_prereqs
  local rev=$BUILD_REV
  local builddir="$SCROLL_DIR/builddir"

  # builddir 不存在时做首次 setup；已存在则只增量编译。
  if [ ! -f "$builddir/build.ninja" ]; then
    info "首次构建：meson setup builddir"
    ( cd "$SCROLL_DIR" && meson setup builddir && meson setup builddir --reconfigure ) \
      || { err "meson setup 失败，检查 docs/scroll-build.md §1 的系统依赖（尤其 libdisplay-info-dev + hwdata）"; return 1; }
  fi

  info "编译 scroll"
  meson compile -C "$builddir" 2>&1 | tail -5

  local sc_hash
  sc_hash=$(git -C "$SCROLL_DIR" rev-parse --short=8 HEAD)

  # ===== 暂存树 =====
  info "meson install 暂存到 $DEB_OUT/scroll-root"
  rm -rf "$DEB_OUT/scroll-root"
  mkdir -p "$DEB_OUT/scroll-root" "$DEB_OUT/debian"
  meson install -C "$builddir" --destdir "$DEB_OUT/scroll-root" --no-rebuild >/dev/null

  # ===== 依赖推导 =====
  # dpkg-shlibdeps 必须在含 debian/control 的目录下运行，否则报
  # "cannot read debian/control" (exit 25)。stderr 单独留档，失败时打印，
  # 不要静默吞掉 —— 之前就因静默中断而「编译完了却没产出 deb」。
  cat > "$DEB_OUT/debian/control" <<'EOF'
Source: scroll-loong64
Section: x11
Priority: optional
Maintainer: local-build <local@build>

Package: scroll
Architecture: loong64
Description: Scroll Wayland compositor (sway fork)
EOF

  local deps_file="$DEB_OUT/scroll-deps.txt"
  local shlib_err="$DEB_OUT/scroll-shlib-err.txt"
  if ! ( cd "$DEB_OUT"
         dpkg-shlibdeps --ignore-missing-info -O \
           -e scroll-root/usr/local/bin/scroll \
           -e scroll-root/usr/local/bin/scrollbar \
           -e scroll-root/usr/local/bin/scrollmsg \
           -e scroll-root/usr/local/bin/scrollnag > "$deps_file" 2> "$shlib_err" ); then
    err "dpkg-shlibdeps 失败："
    cat "$shlib_err" >&2
    return 1
  fi
  local scroll_deps
  scroll_deps=$(sed -n 's/^shlibs:Depends=//p' "$deps_file")
  [ -n "$scroll_deps" ] || { err "依赖推导结果为空，请检查 $deps_file"; return 1; }
  ok "依赖: $scroll_deps"

  # ===== control + 钩子 =====
  mkdir -p "$DEB_OUT/scroll-root/DEBIAN"
  cat > "$DEB_OUT/scroll-root/DEBIAN/control" <<EOF
Package: scroll
Version: 0.0~scroll.$sc_hash-$rev
Section: x11
Priority: optional
Architecture: loong64
Depends: $scroll_deps
Recommends: xwayland
Maintainer: local-build <local@build>
Description: Scroll - a Sway fork Wayland compositor (self-built)
 PaperWM-style tiling Wayland compositor (sway fork) with wlroots 0.21.0
 vendored. Provides scroll/scrollmsg/scrollbar/scrollnag, the Scroll
 wayland-session entry, default config and shell completions.
EOF
  cat > "$DEB_OUT/scroll-root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
case "$1" in configure|abort-upgrade) ldconfig ;; esac
EOF
  cat > "$DEB_OUT/scroll-root/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
case "$1" in remove|purge) ldconfig ;; esac
EOF
  chmod 755 "$DEB_OUT/scroll-root/DEBIAN/postinst" "$DEB_OUT/scroll-root/DEBIAN/postrm"

  # ===== 封包 =====
  local sc_deb="$DEB_OUT/scroll_0.0~scroll.${sc_hash}-${rev}_loong64.deb"
  dpkg-deb --build --root-owner-group "$DEB_OUT/scroll-root" "$sc_deb"
  ok "打包完成: $sc_deb ($(du -h "$sc_deb" | cut -f1))"

  # ===== 校验 =====
  info "校验 1: ldd 无缺失"
  local bad=0
  for b in scroll scrollbar scrollmsg scrollnag; do
    if ldd "$DEB_OUT/scroll-root/usr/local/bin/$b" 2>&1 | grep -q 'not found'; then
      err "$b 有未解析的动态库"; bad=1
    fi
  done
  [ "$bad" -eq 0 ] && ok "四个二进制 ldd 均无 not found"
  info "校验 2: dpkg -i --dry-run"
  dpkg -i --dry-run "$sc_deb" 2>&1 | tail -4 || warn "dry-run 报告依赖未满足，请用 apt-get -f install 补齐"

  echo
  info "安装: sudo dpkg -i $sc_deb && sudo apt-get -f install"
  info "会话: sudo loong64/scripts/enable-session.sh   (LightDM 软链)"
}

cmd_sync(){ cmd_update; cmd_rebuild; }

usage(){
  cat <<'USG'
用法: track-scroll.sh [check|update|rebuild|sync]

  check    拉取上游并报告差异（默认，安全不改文件）
  update   将 scroll 切到上游最新 commit
  rebuild  重编并重新打包 scroll deb
  sync     update + rebuild 一步到位

版本号策略: 0.0~scroll.<8位上游hash>-<本地修订>
  - 上游 hash 变化 → 本地修订从 1 重新计数
  - 同一 hash 多次本地修订 → 递增 2/3/…（BUILD_REV=2）

环境变量: BUILD_ROOT SCROLL_DIR DEB_OUT SCROLL_REMOTE SCROLL_BRANCH BUILD_REV
USG
}

case "${1:-check}" in
  check)   cmd_check ;;
  update)  cmd_update ;;
  rebuild) cmd_rebuild ;;
  sync)    cmd_sync ;;
  -h|--help|help) usage ;;
  *) err "未知子命令: $1"; usage; exit 1 ;;
esac

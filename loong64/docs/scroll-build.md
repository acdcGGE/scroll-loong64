# Scroll 在 loong64 上的编译、打包与会话配置

> 目标平台：Deepin 25（loong64 / LoongArch）
> 工具链：**系统 gcc 即可**（scroll 是纯 C 合成器，wlroots vendored，不需要 gcc-14）
> 产物：独立 deb `scroll_0.0~scroll.<hash>-1_loong64.deb`
> 本仓库：https://github.com/acdcGGE/scroll-loong64 （工程文件在 `loong64` 分支的 `loong64/` 目录）
> 配套文档：桌面 shell 的编译 / 私有运行时 / 注销修复 / `noctalia msg` 动作清单，见
> [noctalia-loong64 工程文档](https://github.com/acdcGGE/noctalia-loong64/blob/loong64/loong64/docs/noctalia-build.md)

---

## 0. 这是什么、为什么要单独编

scroll 是 [sway](https://github.com/swaywm/sway) 的 fork（PaperWM 风格滚动平铺），自带 vendored 的 wlroots 0.21.0，是**纯 C Wayland 合成器**。它承载 noctalia 桌面 shell，但两者是**互相独立、可分别升级的两个 deb**。

- 本仓库只讲 **scroll**：编译、打包、会话入口（LightDM）、`~/.config/scroll/config` 配置、输入法、快捷键机制、追踪上游。
- 桌面 shell（noctalia，C++23，需要 gcc-14.4.0 与私有运行时）在[另一个仓库](https://github.com/acdcGGE/noctalia-loong64/tree/loong64/loong64)。
- scroll 的依赖**全部是系统库**，不捆绑任何私有运行时，包体约 7.5 MB。

**scroll 不需要 gcc-14**：C 项目，系统的 gcc-12.3 足够。gcc-14.4.0 只是 noctalia 才需要。本仓库的 `scripts/track-scroll.sh` 也只管 scroll 一个仓库，不耦合 noctalia。

> 下文形如 `loong64/scripts/xxx.sh` 的命令，默认你在**本仓库克隆的根目录**执行；工程文件都在 `loong64` 分支的 `loong64/` 目录里。

---

## 1. 系统依赖

```bash
sudo apt-get install -y \
  meson ninja-build \
  libwayland-dev libwayland-protocols \
  libxkbcommon-dev libinput-dev libdrm-dev \
  libgbm-dev libegl1-mesa-dev libgles2-mesa-dev \
  libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev \
  libdisplay-info-dev hwdata \
  libjson-c-dev libpcre2-dev libevdev-dev \
  libseat-dev libsystemd-dev libudev-dev \
  libxcb-composite0-dev libxcb-ewmh-dev libxcb-icccm-dev \
  libxcb-render0-dev libxcb-res0-dev libxcb-shape0-dev libxcb-xfixes0-dev \
  liblua5.4-dev libreadline-dev liblcms2-dev libpixman-1-dev
```

**`libdisplay-info-dev` + `hwdata` 是 DRM 后端必需**：缺了会编译出「能用但没有 DRM 输出」的 scroll，只能 X11 回退。装好后再 `meson setup builddir --reconfigure`，确认输出里 `drm-backend: YES`。

`libliftoff` 是可选依赖，Deepin 源没有打包，meson 报 `libliftoff: NO` 属正常，不影响 DRM 输出。编译时 `subprojects/` 下会自动生成两个 `wrap-redirect` 文本文件，是 meson 副产物，**不要提交**（本仓库 `.gitignore` 已排除）。

> 中文 locale 的隐藏坑：Deepin 源的 `apt-cache` 输出是「候选:」而非「Candidate:」，容易误判包不存在。看不准时用 `apt-cache search` 或 `apt-get download <pkg>` 试探。

---

## 2. 编译

```bash
export BUILD_ROOT=$HOME/build
mkdir -p "$BUILD_ROOT"
git clone https://github.com/dawsers/scroll "$BUILD_ROOT/scroll"
cd "$BUILD_ROOT/scroll"

meson setup builddir
# 装好 libdisplay-info-dev + hwdata 后重 configure，确认 drm-backend: YES
meson setup builddir --reconfigure
meson compile -C builddir
```

验证：

```bash
./builddir/sway/scroll --version     # 应输出 1.13-dev
meson configure builddir | grep -i drm
```

产物（在 `builddir/`）：

| 文件 | 说明 |
|---|---|
| `sway/scroll` | 合成器本体（约 13 MB） |
| `swaymsg/scrollmsg` | IPC 工具——**叫 scrollmsg，不是 swaymsg** |
| `swaybar/scrollbar` | 状态栏 |
| `swaynag/scrollnag` | 提示框 |

> 这个命名差异是 noctalia「注销无反应」bug 的根源，见 [noctalia 文档 §4](https://github.com/acdcGGE/noctalia-loong64/blob/loong64/loong64/docs/noctalia-build.md)。

---

## 3. 打包成独立 deb

直接跑工程脚本（`scripts/track-scroll.sh rebuild`），或按下面手工走一遍。scroll 的包只含系统库依赖，不捆绑任何私有运行时，比 noctalia 简单。

```bash
export DEB_OUT="$BUILD_ROOT/deb"
mkdir -p "$DEB_OUT/scroll-root"
meson install -C "$BUILD_ROOT/scroll/builddir" \
  --destdir "$DEB_OUT/scroll-root" --no-rebuild
```

安装布局（由 meson 决定，前缀 `/usr/local`）：四个二进制 → `/usr/local/bin/`；默认配置 → `/usr/local/etc/scroll/config`；会话入口 → `/usr/local/share/wayland-sessions/scroll.desktop`；壁纸、图标、shell 补全 → `/usr/local/share/`。

### 3.1 依赖推导（注意 `debian/control` 坑）

`dpkg-shlibdeps` **必须在含 `debian/control` 的目录下运行**，否则报 `error: cannot read debian/control`（exit 25），且这个错误很容易被 `2>/dev/null` 吞掉、表现为「编译完了却没产出 deb」。先放一份最小 control，再 `cd $DEB_OUT` 执行：

```bash
mkdir -p "$DEB_OUT/debian"
cat > "$DEB_OUT/debian/control" <<'EOF'
Source: scroll-loong64
Section: x11
Priority: optional
Maintainer: local-build <local@build>

Package: scroll
Architecture: loong64
Description: Scroll Wayland compositor (sway fork)
EOF

( cd "$DEB_OUT"
  dpkg-shlibdeps --ignore-missing-info -O \
    -e scroll-root/usr/local/bin/scroll \
    -e scroll-root/usr/local/bin/scrollbar \
    -e scroll-root/usr/local/bin/scrollmsg \
    -e scroll-root/usr/local/bin/scrollnag > /tmp/scroll-deps.txt )
SCROLL_DEPS=$(sed -n 's/^shlibs:Depends=//p' /tmp/scroll-deps.txt)
```

scroll 的依赖全是系统库，**无需剔除**任何项（对比 noctalia 需要剔除已私有打包的 `libstdc++6` / `libgcc-s1`）。

### 3.2 control + 钩子 + 封包

```bash
SC_HASH=$(git -C "$BUILD_ROOT/scroll" rev-parse --short=8 HEAD)
mkdir -p "$DEB_OUT/scroll-root/DEBIAN"
cat > "$DEB_OUT/scroll-root/DEBIAN/control" <<EOF
Package: scroll
Version: 0.0~scroll.$SC_HASH-1
Section: x11
Priority: optional
Architecture: loong64
Depends: $SCROLL_DEPS
Recommends: xwayland
Maintainer: local-build <local@build>
Description: Scroll - a Sway fork Wayland compositor (self-built)
 PaperWM-style tiling Wayland compositor (sway fork) with wlroots 0.21.0
 vendored. Provides scroll/scrollmsg/scrollbar/scrollnag, the Scroll
 wayland-session entry, default config and shell completions.
EOF
```

`DEBIAN/postinst` / `DEBIAN/postrm`（`chmod 755`）：

```sh
#!/bin/sh
set -e
case "$1" in configure|abort-upgrade) ldconfig ;; esac   # postinst
# postrm 把上一行的 configure|abort-upgrade 换成 remove|purge
```

```bash
dpkg-deb --build --root-owner-group \
  "$DEB_OUT/scroll-root" "$DEB_OUT/scroll_0.0~scroll.${SC_HASH}-1_loong64.deb"
dpkg -i --dry-run "$DEB_OUT"/scroll_*.deb       # 校验依赖可满足
ldd "$DEB_OUT/scroll-root/usr/local/bin/scroll" | grep 'not found' || echo "OK: 无缺失"
```

版本号策略 `0.0~scroll.<8位上游hash>-<本地修订>`：上游 hash 变化时修订号从 1 重新计；同一 hash 的本地修订（如改打包逻辑）递增 2/3/…（用 `BUILD_REV` 环境变量覆盖）。

---

## 4. 安装与登录会话

```bash
sudo dpkg -i "$DEB_OUT"/scroll_*.deb
sudo apt-get -f install
which scroll scrollmsg scrollbar scrollnag
```

noctalia 是**可选的配套桌面 shell**，需要时另行安装对应 deb（见 [noctalia 仓库](https://github.com/acdcGGE/noctalia-loong64/tree/loong64/loong64)）。只装 scroll 也能直接作为纯合成器使用，只是没有面板 / 启动器 / 通知中心。

### 4.1 LightDM 只扫 /usr/share —— 必须软链会话入口

Deepin 的 LightDM 默认**只扫描 `/usr/share/wayland-sessions`**，而 deb 把 `scroll.desktop` 装到了 `/usr/local/share/wayland-sessions`，所以登录界面看不到 Scroll（只剩 xfce4）。用软链同步（以后重装 deb 也生效）：

```bash
sudo loong64/scripts/enable-session.sh
# 等价于：
sudo mkdir -p /usr/share/wayland-sessions
sudo ln -sf /usr/local/share/wayland-sessions/scroll.desktop \
           /usr/share/wayland-sessions/scroll.desktop
```

然后**注销回到登录界面**（或 `sudo systemctl restart lightdm`），会话菜单出现 **Scroll**，选它登录即进入合成器。

> 兜底：没有图形登录器时，`Ctrl+Alt+F2` 切 TTY 登录后直接跑 `scroll`。
> ⚠️ 别和 Deepin 自带 DDE 同时跑——两个合成器抢显示。

---

## 5. 会话配置 `~/.config/scroll/config`

```bash
mkdir -p ~/.config/scroll
[ -f ~/.config/scroll/config ] || cp /usr/local/etc/scroll/config ~/.config/scroll/config
```

改完无需重启会话，`scrollmsg reload` 即可生效。仓库 [`config/scroll-config.snippet`](https://github.com/acdcGGE/scroll-loong64/blob/loong64/loong64/config/scroll-config.snippet) 是一份可直接追加的示例。

### 5.1 自启动程序

最小配置（纯合成器，无桌面 shell）：

```ini
bindsym $mod+Return exec wezterm
exec --no-startup-id fcitx5 -d
```

若装了 noctalia，加一行让它随会话启动：

```ini
exec --no-startup-id noctalia --daemon
```

配合输入法时顺序很重要：**fcitx5 必须在 noctalia 和任何 GUI 应用之前**（见 §6.3）。

### 5.2 快捷键机制（bindsym）

全局快捷键属于合成器职责，noctalia 自身不管。语法就是标准 sway/scroll 的 `bindsym`，`$mod` 默认是 **Win 键（Mod4）**：

```ini
bindsym $mod+Return exec wezterm
bindsym $mod+space  exec "noctalia msg panel-toggle launcher"
```

第二行是 noctalia 配套示例；`noctalia msg <动作>` 的完整示例与动作清单见 [noctalia 文档 §7](https://github.com/acdcGGE/noctalia-loong64/blob/loong64/loong64/docs/noctalia-build.md)。改完 `scrollmsg reload` 生效，**无需重启会话**。

---

## 6. 输入法配置（fcitx5）

scroll 是 wlroots 合成器，原生支持 `text-input-v3` + `zwp_input_method_v2`，用 **fcitx5** 最合适（fcitx4 在 Wayland 下支持很差）。最小配置是「apt 安装 + 两个文件」：`~/.profile`（环境变量）与 `~/.config/scroll/config`（会话内启动）。仓库 [`config/profile.snippet`](https://github.com/acdcGGE/scroll-loong64/blob/loong64/loong64/config/profile.snippet) 可直接追加。

### 6.1 安装（apt）

```bash
sudo apt-get install -y \
  fcitx5 fcitx5-chinese-addons \
  fcitx5-frontend-gtk3 fcitx5-frontend-gtk2 \
  fcitx5-frontend-qt5 fcitx5-frontend-qt6 \
  fcitx5-module fcitx5-configtool
```

- `fcitx5-chinese-addons` 提供拼音等中文引擎，**装完还需挂接输入法**（见 §6.4）。
- 若用 Rime：`sudo apt-get install fcitx5-rime`。
- 若装的是旧版 fcitx4，启动命令改为 `fcitx -d`，其余环境变量相同。

### 6.2 环境变量（写入 `~/.profile`）

```sh
# ~/.profile 末尾追加
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
```

- `QT_IM_MODULE=fcitx` **必设**：Qt 在 Wayland 非 KDE 环境没有 text-input-v2，只能走 fcitx 输入法模块，否则 Qt 程序（WPS、Anki 等）无法输入中文。
- `XMODIFIERS=@im=fcitx` 供 XWayland 下的 X11 程序使用。
- GTK3/4 原生走 text-input-v3，显式设 `fcitx` 对非 KDE 更稳。
- **不要写在 `.bashrc`**（只对交互 shell 生效，不传给 GUI 会话）。

⚠️ LightDM 启动 Wayland 会话时不一定 source `~/.profile`。本环境实测可行；若 GUI 程序仍无法输入，改用更稳妥的任一方式：

- 在 `/etc/environment` 写同样四行（pam-env 全局生效，需 sudo）；或
- 在 `~/.config/scroll/config` 顶部用 `exec export` 注入（见下），只影响本会话、优先级最高。

### 6.3 会话内启动（写入 `~/.config/scroll/config` 顶部）

务必在 `exec noctalia --daemon` 及任何 GUI 应用**之前**：

```ini
# --no-startup-id 避免 sway 等待；-d 后台运行
exec --no-startup-id fcitx5 -d

# 若 §6.2 的环境变量未被会话继承，在此强制注入：
exec export GTK_IM_MODULE=fcitx
exec export QT_IM_MODULE=fcitx
exec export XMODIFIERS=@im=fcitx
exec export SDL_IM_MODULE=fcitx

# 之后才是桌面 shell 和应用（noctalia 可选）
exec --no-startup-id noctalia --daemon
```

```bash
scrollmsg reload           # 无需注销即可重载
fcitx5 -d &                # 已登录时可手动起一次
```

### 6.4 挂接中文输入法（首次必做）

```bash
fcitx5-configtool
```

在「输入法」标签页取消勾选「只显示当前语言」，找到 **拼音 / Pinyin** 添加到左侧当前分组并应用。否则托盘图标在、但只有「英」没有「中」。

### 6.5 常见排查

- **能切换不能输入**：dbus 会话总线没传给 fcitx 组件，config 顶部加：
  ```ini
  exec dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
  ```
- **Qt 程序不生效**：确认 `QT_IM_MODULE=fcitx` 已设，且装了 `fcitx5-frontend-qt5`/`qt6`。
- **候选框位置乱/不显示**：Wayland 下候选框由合成器定位，scroll 支持 `zwp_input_method_v2`；异常时 `fcitx5 -r` 或重载会话。

---

## 7. 追踪上游更新

本仓库的 `scripts/track-scroll.sh` **只管 scroll 一个仓库**（noctalia 有自己的脚本，互不耦合）：

```bash
loong64/scripts/track-scroll.sh check     # 拉取上游，报告差异（安全，不改文件）
loong64/scripts/track-scroll.sh update    # 切到 origin/master 最新（detached HEAD）
loong64/scripts/track-scroll.sh rebuild   # 重编 + 重打 scroll deb
loong64/scripts/track-scroll.sh sync      # update + rebuild 一步到位
```

`update` 用 `git checkout -f origin/master` 强制覆盖本地改动（scroll 上游默认分支是 **`master`**，不是 main）。`rebuild` 的流程：前置检查 → `meson compile` → `meson install --destdir` 暂存 → 在 `$DEB_OUT` 生成 `debian/control` 后跑 `dpkg-shlibdeps` 推导系统库依赖 → 写 control + ldconfig 钩子 → `dpkg-deb` 封包 → `dpkg -i --dry-run` 校验。

全部路径可用环境变量覆盖：`BUILD_ROOT`（默认 `$HOME/build`）、`SCROLL_DIR`、`DEB_OUT`、`SCROLL_BRANCH`、`BUILD_REV`。换机复用改这几个变量即可。

scroll 是纯 C 项目，增量编译很快（通常几十秒），不像 noctalia 的 C++23 全量重链那么耗时。

---

## 附录 A：路径清单

| 路径 | 用途 |
|---|---|
| `$BUILD_ROOT/scroll` | scroll 源码 + `builddir` |
| `$BUILD_ROOT/deb/scroll-root` | 打包暂存树 |
| `/usr/local/bin/scroll{msg,bar,nag}` | 四个二进制 |
| `/usr/local/share/wayland-sessions/scroll.desktop` | deb 安装的会话入口（需软链到 `/usr/share`） |
| `/usr/local/etc/scroll/config` | 默认配置模板 |
| `~/.config/scroll/config` | 用户会话配置：自启动、快捷键、fcitx5 |
| `~/.profile` | 输入法环境变量 |
| `loong64/scripts/track-scroll.sh` | 追踪上游 + 重编重打包 |
| `loong64/scripts/enable-session.sh` | LightDM 会话入口软链 |

## 附录 B：命令速查

```bash
# 编译
meson setup builddir && meson setup builddir --reconfigure
meson compile -C builddir
./builddir/sway/scroll --version

# 打包
loong64/scripts/track-scroll.sh rebuild

# 会话入口
sudo loong64/scripts/enable-session.sh

# 配置 / 生效
scrollmsg reload
scrollmsg -t get_outputs
fcitx5-configtool
fcitx5 -r

# 追踪上游
loong64/scripts/track-scroll.sh check
loong64/scripts/track-scroll.sh sync
```

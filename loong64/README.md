# Scroll on loong64

在 **Deepin 25（loong64 / LoongArch）** 上编译、打包、部署 [scroll](https://github.com/dawsers/scroll)（sway fork / PaperWM 风格滚动平铺 Wayland 合成器）的移植工程文件。

本目录位于仓库的 **`loong64` 分支**，只新增文件，**不改动 scroll 上游源码**；`master` 分支保持为上游镜像。

> 配套桌面 shell [noctalia](https://github.com/noctalia-dev/noctalia)（C++23，需要 gcc-14.4.0 与私有运行时）在**另一个仓库**：
> https://github.com/acdcGGE/noctalia-loong64/tree/loong64/loong64
> 两个项目是互相独立、可分别升级的 deb。

---

## 为什么需要这套东西

| 问题 | 处理 |
|---|---|
| scroll 不在 Deepin 源里，且 loong64 无预编译包 | 用 meson 源码编译并打成独立 deb |
| `libdisplay-info-dev` + `hwdata` 缺失会编出「无 DRM 输出」的半成品 | §1 依赖清单里列为必需，装完 `--reconfigure` 确认 `drm-backend: YES` |
| `dpkg-shlibdeps` 缺 `debian/control` 会静默中断打包 | `track-scroll.sh` 先生成 control 并切到输出目录执行 |
| LightDM 只扫 `/usr/share/wayland-sessions` | `enable-session.sh` 建软链 |
| Wayland 下中文输入 | fcitx5 + `~/.profile` 环境变量 + 会话内 `exec` 启动 |
| IPC 工具叫 `scrollmsg` 而非 `swaymsg` | 文档与配置示例统一用 `scrollmsg`；这也是 noctalia 注销 bug 的根源 |

**scroll 不需要 gcc-14**：纯 C 项目，系统 gcc-12.3 足够，deb 只依赖系统库、不捆绑任何私有运行时（约 7.5 MB）。gcc-14.4.0 只是 noctalia 才需要。

产物：`scroll_0.0~scroll.<8位上游hash>-<本地修订>_loong64.deb`。

---

## 目录结构

```
loong64/
├── README.md                       本文件
├── docs/
│   └── scroll-build.md             Scroll 编译 / 打包 / 会话 / 输入法（独立完整文档）
├── scripts/
│   ├── track-scroll.sh             追踪上游 + 重编重打包（check/update/rebuild/sync）
│   └── enable-session.sh           LightDM 会话入口软链（需 sudo）
└── config/
    ├── scroll-config.snippet        ~/.config/scroll/config 片段（输入法/自启/快捷键）
    └── profile.snippet              ~/.profile 输入法环境变量片段
```

`docs/scroll-build.md` 是**自洽的单项目文档**：从 apt 依赖、meson 编译、deb 打包、LightDM 会话、`~/.config/scroll/config`、fcitx5 输入法到追踪上游，全部覆盖；涉及配套 shell 处用链接指向 noctalia 仓库。

---

## 快速开始

```bash
# 1. 装系统依赖（见 docs/scroll-build.md §1，尤其 libdisplay-info-dev + hwdata）
# 2. 克隆源码到 $HOME/build/scroll（脚本默认路径，可用 SCROLL_DIR 覆盖）
git clone https://github.com/dawsers/scroll "$HOME/build/scroll"

# 3. 编译 + 打包（首次会自动 meson setup）
loong64/scripts/track-scroll.sh rebuild

# 4. 安装（必须用 apt：control 声明了 Conflicts/Replaces: noctalia-desktop，
#    apt 会自动移除旧合并包；dpkg -i 不处理冲突会直接失败）
sudo apt install "$HOME"/build/deb/scroll_*.deb

# 5. 启用登录会话入口
sudo loong64/scripts/enable-session.sh

# 6. 会话配置（输入法 / 自启 / 快捷键），参考 config/ 下两个 snippet
mkdir -p ~/.config/scroll
[ -f ~/.config/scroll/config ] || cp /usr/local/etc/scroll/config ~/.config/scroll/config
```

之后追上游：

```bash
loong64/scripts/track-scroll.sh check     # 安全：只看有无新提交
loong64/scripts/track-scroll.sh sync      # 一键 update + 重编 + 重打包
```

脚本全部路径可用环境变量覆盖：`BUILD_ROOT`（默认 `$HOME/build`）、`SCROLL_DIR`、`DEB_OUT`、`SCROLL_REMOTE`（默认 `origin`，想直连上游设 `upstream`）、`SCROLL_BRANCH`（默认 `master`）、`BUILD_REV`。

---

## 已固化的踩坑处理

1. **`dpkg-shlibdeps` 必须在含 `debian/control` 的目录运行**，否则 `error: cannot read debian/control`（exit 25）会中断打包。脚本 stderr 单独留档、失败立即打印，不再静默失败导致「编译完了却没 deb」。
2. **scroll 上游默认分支是 `master`**，不是 `main`；`update` 用 `git checkout -f` 强制覆盖本地改动。
3. **`libdisplay-info-dev` + `hwdata` 决定 DRM 后端**，缺了只能 X11 回退；`libliftoff` 是可选依赖，报 `NO` 不影响输出。
4. **`subprojects/*.wrap` 是 meson 自动生成的 `wrap-redirect` 副产物**，不是移植补丁，不要提交（`.gitignore` 已排除）。
5. **IPC 工具名是 `scrollmsg`**（`scrollbar` / `scrollnag` 同理），不是 sway 系命名；配置与排错都用 `scrollmsg reload`。
6. **不要事后用 patchelf 改 RUNPATH**（scroll 用不到，但配套 noctalia 的 60MB+ 二进制会触发 `virtual address space underrun`）。

---

## 平台与工具链

- OS：Deepin 25 "beige"，arch `loong64`
- 编译器：系统 gcc（C 项目，无需 gcc-14）
- 构建：meson + ninja；打包：dpkg-deb / dpkg-shlibdeps
- 输入法：fcitx5（Wayland text-input-v3 + zwp_input_method_v2）

## 上游与许可

scroll 上游许可见其仓库 [LICENSE](../LICENSE)；本目录仅为 loong64 平台的构建/打包工程文件与文档。

- scroll 上游：https://github.com/dawsers/scroll
- 配套 noctalia 移植工程：https://github.com/acdcGGE/noctalia-loong64/tree/loong64/loong64

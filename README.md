# cs2549-omarchy

**English TL;DR:** This repo makes the built-in fingerprint **power button** of the
MECHREVO Code 01 (TongFang Uniwill PF5NU1G) — USB `2541:2549`
"AB2CD.COM USB FingPintComp", a KiKA / ChipSailing CS2549-family *match-on-host*
sensor — work on **Omarchy / Arch Linux**. It automates building the open-source
[`subhashdasyam/KiKAID-A3-linux`](https://github.com/subhashdasyam/KiKAID-A3-linux)
libfprint driver (with the SIGFM software matcher) against current Arch packages,
installs it side-by-side (no system libfprint touched), and wires it into PAM for
**lock screen + sudo** fingerprint authentication. Enrolled Windows Hello templates
are neither read nor modified; dual-boot is unaffected.

---

## 这是什么

机械革命 Code 01（同方 Uniwill PF5NU1G 准系统）的**指纹电源键**在 Linux 下没有任何官方支持：

| | |
|---|---|
| USB ID | `2541:2549`（VID 未在 usb.ids 注册，私有） |
| 字符串 | `AB2CD.COM USB FingPintComp`（深圳奇甲 / KiKA，CS2549 方案） |
| 接口 | 0/2 = vendor HID；**接口 1 = bulk 数据口（EP 0x01 OUT / 0x81 IN，64 字节）** |
| 工作方式 | **match-on-host 传图式**：传感器输出 112×88 原始指纹图，比对在主机软件完成，模块本身不存模板 |

libfprint 官方支持列表和 unsupported 列表都没有它，GitHub 上原本只有 UOS/银河麒麟的闭源驱动
（`com.ab2cd.sfm-a03`，深度绑定 deepin-authentication / UKUI libbiometric，无法在 Arch 使用）。
上游 [`KiKAID-A3-linux`](https://github.com/subhashdasyam/KiKAID-A3-linux) 为同一 USB ID
的 KiKAID A3 指纹鼠标逆向出了开源 libfprint 驱动（`cs2549`），经实测接口布局与 Code 01 的
内置指纹键一致，可直接驱动。

本仓库提供 `port-arch.sh`，把上游驱动在 **Arch 当前软件包**下的适配坑全部自动化：

- `glib-mkenums` 在 Arch 拆分到了 `glib2-devel` 包（Debian 合并在 glib2 里）；
- Arch 现为 OpenCV 5（`opencv5.pc`），上游 fork 写的是 `opencv4` → meson 依赖名放宽为两者都试；
- fork 的 SIGFM 单元测试强依赖 `doctest`（Arch 仅 AUR 有）→ 改为可选，不拉 AUR；
- sudo 运行时 `$HOME` 变化 → 脚本以自身路径为基准，不受影响。

## 安装步骤

前提：Omarchy / Arch x86_64，用户有 sudo/wheel 权限。全程三条 sudo 命令。

```sh
git clone https://github.com/onlymykazari/cs2549-omarchy
cd cs2549-omarchy

sh port-arch.sh fetch                 # 克隆上游驱动 + 下载锁定版 libfprint fork（sha256 校验）
sudo sh port-arch.sh deps             # 安装构建依赖（base-devel/meson/opencv/fprintd 等，约 1GB）
sh port-arch.sh build                 # 编译 cs2549 驱动 + SIGFM 匹配器，并跑单元测试
sudo sh port-arch.sh install          # 安装到 /opt/libfprint-cs2549 + fprintd systemd 覆盖

fprintd-enroll -f right-thumb         # 本地终端里录指纹（拇指成功率最高；平放压实停 1 秒再抬起）
fprintd-verify -f right-index-finger  # 期望输出 verify-match

sudo sh port-arch.sh pam             # sudo/polkit/锁屏 接入指纹（omarchy 官方布局）
```

`pam` 按 **Omarchy 官方布局**（与 `omarchy-setup-security-fingerprint` 一致）配置三处：

- `/etc/pam.d/sudo`、`/etc/pam.d/polkit-1`：合盖门槛行 + `auth sufficient pam_fprintd.so`（开盖时指纹优先，合盖自动跳过回退密码）；
- `/etc/pam.d/omarchy-lock-fingerprint`：锁屏检测到这个文件 + fprintd 里有已录指纹时，会**自动启用原生指纹 UI**（触摸随时解锁，密码框不受影响）。

注意：**不要**把 `pam_fprintd` 塞进 `omarchy-lock-password` / `system-auth` 这类密码栈——串行 PAM 流程会让每次输密码都先阻塞等待指纹超时。

另外，omarchy 首启的指纹检测（`omarchy-hw-fingerprint`）在这台机器上会漏检：VID `2541` 不在其白名单，且该传感器产品字符串是厂商拼写错误的 "USB Fing**P**intComp"（少了 r），匹配不上 "fingerprint" 子串——所以本仓库的手动移植才有必要。

## 已验证环境

| 组件 | 版本 |
|---|---|
| 系统 | Omarchy 4.0.6（Arch），内核 `7.2.8-9-omarchy` |
| fprintd | 1.94.5-2 |
| 系统 libfprint（未改动） | 1.94.100-1 |
| OpenCV | 5.0.0-13 |
| glib2 | 2.90.1-1 |
| 上游驱动 commit | `986b334`（2026-09-17） |
| 锁定 libfprint fork | `archeYR/libfprint-CS9711@02b285c`（SIGFM 匹配器） |
| 日期 | 2026-11 |

## 安装形态与回滚

- 驱动库：`/opt/libfprint-cs2549/lib/libfprint-2.so.2`
- fprintd 覆盖：`/etc/systemd/system/fprintd.service.d/50-cs2549.conf`（仅设置 `LD_LIBRARY_PATH`）
- **系统自带的 libfprint、fprintd、PAM 机制均不改动**；Arch 更新 fprintd 不受影响
- 一键回滚：`sudo sh port-arch.sh rollback`（删除上述两处 + 还原 PAM 备份）

## 注意事项

- 上游驱动是**实验性质**：作者未做误识率（FAR）与假指纹防伪测试。日常解锁 sudo/锁屏足够，请勿将其视为安全边界。
- **SSH 远程 sudo 会先等 10 秒**指纹超时再提示密码（指纹传感器是本地设备，远程按不了）。介意的话把 `system-auth` 里那行删掉、只保留锁屏 PAM（`pam lock` 模式）。
- SDDM 自动登录（Omarchy 默认）不经过指纹；若以后关闭 autologin，需要再往 `/etc/pam.d/sddm` 加同样的行。
- 双系统：Windows Hello 的模板存放在 TPM 中，Linux 录入互不干扰；Windows "快速启动"热重启后若指纹键无响应，彻底关机一次即可。
- enrolldata 存放于 `/var/lib/fprint/`，Windows 侧不可见；同理 Windows 录入的模板 Linux 也不可用（需在 Linux 重新录入一次）。

## 致谢

- [`subhashdasyam/KiKAID-A3-linux`](https://github.com/subhashdasyam/KiKAID-A3-linux) — cs2549 开源 libfprint 驱动
- [`archeYR/libfprint-CS9711`](https://github.com/archeYR/libfprint-CS9711) — 集成 SIGFM 匹配器的 libfprint fork
- [fprintd / libfprint](https://fprint.freedesktop.org/)、[SIGFM](https://github.com/serg1or/SIGFM) 项目

## License

LGPL-2.1（与上游一致）。

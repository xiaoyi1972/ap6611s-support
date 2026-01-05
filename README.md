AP6611S brcmfmac patch + installer

简介
- 本仓库包含将 PR 改动移植到 Linux 6.18.3 的补丁以及一个安装脚本，用于编译并安装修补后的 `brcmfmac` 驱动和指定的 Rockchip DTB。

前提条件
- 运行在支持 sudo 的 Debian/Ubuntu 系统上（脚本使用 apt-get 安装依赖）。
- 目标系统正在运行或兼容 Linux 6.18.3 内核（示例内核版本：6.18.3-edge-rockchip64）。
- 需要网络连接以下载内核源（脚本会在需要时下载 linux-6.18.3.tar.xz）。

重要文件
- `patches/ap6611s-brcmfmac.patch`：合并后的补丁，包含驱动与 DTS 修改。
- `scripts/install_ap6611s.sh`：安装脚本，负责应用补丁、构建模块、构建指定 DTB、安装并加载模块。

快速开始
1. 查看补丁（可选）：

```bash
less patches/ap6611s-brcmfmac.patch
```

2. 运行安装脚本（需要 root）：

```bash
sudo bash scripts/install_ap6611s.sh patches/ap6611s-brcmfmac.patch
```

脚本会执行：
- 安装构建依赖（使用 apt-get）
- 下载并解压 Linux 6.18.3 源（若工作目录不存在）
- 应用补丁到源树
- 构建并安装 `brcmfmac` 模块
- 通过临时 `dtbs-list` 构建并安装指定的 DTB（默认：rk3588-orangepi-5-max/plus/ultra）
- 在退出时会清理临时 `dtbs-list`

验证
- 检查模块是否加载：

```bash
lsmod | grep brcmfmac
```

- 查看 SDIO 设备枚举：

```bash
ls /sys/bus/sdio/devices
```

- 检查内核日志（关注 brcm*、sdio、firmware）：

```bash
dmesg | grep -i brcm
```

还原/回滚
- 脚本会在替换 DTB 或模块前创建备份（以 `.ap6611s.bak` 结尾）。若需要回滚：

```bash
# 恢复模块备份
sudo mv /lib/modules/$(uname -r)/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko.ap6611s.bak /lib/modules/$(uname -r)/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko
sudo depmod -a
sudo modprobe brcmfmac

# 恢复 DTB 备份（示例）
sudo mv /boot/dtb/rockchip/rk3588-orangepi-5-max.dtb.ap6611s.bak /boot/dtb/rockchip/rk3588-orangepi-5-max.dtb
```

开发者备注
- 脚本使用 `arch/arm64/boot/dts/dtbs-list` 临时限制 `make dtbs` 的目标，脚本会在退出时自动恢复或删除该文件。
- 如果你想修改要构建的 DTB，编辑 `DTB_TARGETS` 变量或在运行时覆盖：

```bash
DTB_TARGETS="myboard.dtb" sudo bash scripts/install_ap6611s.sh patches/ap6611s-brcmfmac.patch
```

支持
- 若遇到构建错误或需要进一步调整驱动以支持 AP6611S（SYN43711），请把 `dmesg`、`/var/log/kern.log` 和脚本输出日志发给维护者以便分析。

许可证
- 此仓库仅汇集补丁和脚本，补丁内容应遵守 Linux 内核代码许可条款（GPL）。

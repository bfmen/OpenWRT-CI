# OpenWRT-CI 项目说明

> 供 Claude Code 自动读取的上下文文档。

## 项目概述

基于 VIKINGYFY/immortalwrt（kernel 6.18）的多设备 CI 固件构建项目。
GitHub: https://github.com/ysuolmai/OpenWRT-CI

## 目标设备

| 设备 | 平台 | 备注 |
|------|------|------|
| sx_7981r128 | MTK filogic (MT7981B) | 主要设备，源码里没有，需 CI 注入 |
| nokia_ea0326gmp | MTK filogic (MT7981B) | 白名单保留 |
| cmcc_rax3000m | MTK filogic (MT7981B) | 白名单保留 |

MTK 设备白名单在 `Scripts/diy.sh` 的第 0 节，其他设备从 `.config` 过滤掉。

## SX 7981R128 硬件信息

- **SoC**: MediaTek MT7981B (Cortex-A53 × 2)
- **RAM**: 512MB **DDR3**（已确认，SDK DTS 里的 "ddr2" 注释是 FPGA 模板残留，忽略）
- **Flash**: 128MB SPIM-NAND
- **2.5G PHY**: Airoha EN8801SC，接 MT7531 switch port@5（label: lan2）
- **Switch**: MediaTek MT7531
- **SFP 笼**: 接 gmac1（eth1），自适应，通过 SFP 模块识别速率
- **WiFi**: MT7976（双频 Wi-Fi 6）
- **USB**: USB 3.0

### 网口分配
```
lan1  → MT7531 port@1 → 千兆 LAN
lan2  → MT7531 port@5 → EN8801SC 2.5G → 默认 WAN
eth1  → gmac1 → SFP 笼 → wan2（次要 WAN，uci-defaults 配置）
```

### NAND 分区布局
```
0x000000 - 0x100000  BL2        (1MB,   read-only)
0x100000 - 0x180000  u-boot-env (512KB)
0x180000 - 0x380000  Factory    (2MB,   read-only)
0x380000 - 0x580000  FIP        (2MB,   read-only)
0x580000 - 末尾      UBI        (~122MB, kernel+rootfs)
```

## 关键脚本说明

### 执行顺序（WRT-CORE.yml Custom Settings step）
```
cat Config/*.txt >> .config
→ Scripts/Settings.sh
→ Scripts/diy.sh          ← 我们的自定义逻辑，最后执行，改动优先级最高
→ make defconfig
```

### Scripts/diy.sh 各节职责
| 节 | 内容 |
|----|------|
| [upstream-fix] | 删除上游格式损坏的 globitel patch（会导致 MT7981 uboot 编译失败） |
| [device-add] | 注入 sx_7981r128：DTS 复制、filogic.mk 条目、02_network、uci-defaults |
| UPDATE_PACKAGE | 安装/更新第三方包（poweroff、tailscale、gecoosac、openlist2、jell 批量、netspeedtest 等） |
| provided_config_lines | 写入额外的 .config 配置项 |
| pkg-fix 1/2/3 | iptables → kmod-nf-ipt/iptables-nft 依赖替换 |
| 颜色/文件内置 | CSS 主色 → #31A1A1，安装 uci-defaults 脚本 |
| Makefile 修复 | cmake、getifaddr、v2ray-geodata、rust patch 等 |

### Scripts/dts/mt7981b-sx-7981r128.dts
- 使用 `mt7981b.dtsi`（kernel 6.18 用）
- 包含 spi-cal-* 校准属性
- 内存节点: `<0 0x40000000 0 0x20000000>` = 512MB

## sx_7981r128 FIP / U-Boot

**本仓库只产 `sysupgrade.bin`（sysupgrade-tar），不掺和 U-Boot/FIP/BL2。**

FIP / preloader 在独立仓库构建：<https://github.com/ysuolmai/UBOOT-CI>
- 包含 ATF BL2 + U-Boot DTS + defconfig + defenvs
- 产出 `preloader.bin` + `bl31-uboot.fip`
- 设备硬件：MT7981B + 512MB DDR3-1866（SK Hynix H5TQ4G63EFR-RDC）+ 128MB SPIM-NAND + MT7531 switch（reset GPIO 39）+ EN8801SC 2.5G PHY

## 重要约定

- **Git commit co-author**: `Co-Authored-By: bugwriter <noreply@wahlau.top>`
- **push 前必须先 pull --rebase**：执行 `git pull --rebase origin main` 再 push，严禁直接 force push（会覆盖其他 session 的 commits）
- **WireGuard 相关包已移除**（`kmod-wireguard`、`wireguard-tools`、`luci-proto-wireguard`）
- Docker 相关：EMMC 设备才启用，MTK SPIM-NAND 设备不加

## DAE 支持（IPQ60XX eMMC + MTK filogic 设备）

本项目在 QCA IPQ60XX eMMC **以及** MTK filogic (MT7981B) 设备上额外提供基于 eBPF 的透明代理固件（dae）。

### 相关文件
| 文件 | 说明 |
|------|------|
| `Scripts/diy.sh` 末尾 `[dae]` 块 | 从 `ysuolmai/luci-app-dae` clone 包，IPQ60XX 还扩大 eMMC 内核分区（MTK 用 UBI dynamic volume 无需）|
| `Config/IPQ60XX-DAE-EMMC-WIFI-YES.txt` | QCA + DAE，含 WiFi（参考 IPQ60XX-EMMC-WIFI-YES 设备列表）|
| `Config/IPQ60XX-DAE-EMMC-WIFI-NO.txt` | QCA + DAE，无 WiFi |
| `Config/MTK-DAE-WIFI-YES.txt` | MTK filogic + DAE，含 WiFi（diy.sh 白名单过滤到 sx_7981r128 / nokia_ea0326gmp / cmcc_rax3000m）|

**dae 和 luci-app-dae 包独立维护**：https://github.com/ysuolmai/luci-app-dae
- 包含 dae 主程序包（Makefile/init/UCI）+ LuCI UI（表单/所有节点/文本 三 Tab，含 group/订阅/路由/DNS/全局表单）
- diy.sh 在 DAE 构建时 `git clone --depth=1` 该仓库 **main 分支** 并复制到 `package/`
- **本仓库不需要锁定 luci-app-dae 版本**：每次 OpenWRT-CI 编译都自动拉最新 main → luci-app-dae 改一行 push，下次 OpenWRT-CI 编译就用上
- 该仓库的 Claude 上下文文档：`luci-app-dae/CLAUDE.md`（迭代 UI/解析器时去那边看）

### 与普通构建的区别
- 内核开启 eBPF/BTF/XDP/Cgroup 相关选项
- **QCA 平台**额外启用 SKB Recycler 内存优化（MTK 平台不加，QCA 专属）
- **不包含** openclash / passwall（由 `diy.sh` 末尾 `[dae]` 块清除）
- **QCA EMMC** 内核分区从 6144k 扩大至 12288k（eBPF 编译产物更大；MTK UBI 自动伸缩无需）
- QCA 目标设备：IPQ60XX EMMC 白名单（`redmi_ax5-jdcloud`、`jdcloud_re-ss-01`、`jdcloud_re-cs-07` 等）
- MTK 目标设备：跟 MEDIATEK-WIFI-* 共用 diy.sh 第 0 节白名单（`sx_7981r128` 等 3 台）

### 已知 trade-off（dae vs 硬件加速）
- dae 用 eBPF 接管流量 → **绕过 QCA NSS / MTK WED 硬件加速**
- 直连流量：A53@1.3-1.5GHz 软件转发 ~600-900 Mbps（千兆够用，2.5G 跑不满）
- 代理流量：受加密单核制约 ~200 Mbps（任何透明代理都一样）
- 实测：Redmi AX5 (IPQ60XX) 上 dae 跑通；sx_7981r128 (MT7981B) 待实测 WED 共存情况

## 常见问题

**Q: MTK 设备为什么只编 3 个设备？**
`diy.sh` 第 0 节的白名单 sed 会过滤掉 `.config` 里其他 `CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_*` 行。

**Q: sx_7981r128 为什么要 CI 注入而不是直接 PR 到上游？**
VIKINGYFY/immortalwrt 上游没有这个设备，CI 在构建时动态注入 DTS + filogic.mk 条目。

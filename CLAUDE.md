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

## sx_7981r128 FIP 状态

**当前：仅产出 `sysupgrade.bin`，不产出 FIP。**

原因：没有公开的 sx_7981r128 专属 U-Boot defconfig，无法生成可靠的 FIP。

如要添加 FIP，需要：
1. 在 hanwckf/bl-mt798x 里写 `mt7981_sx_7981r128_defconfig`
   - DDR3 确认 ✅
   - 内存颗粒具体型号 → 待补（拆机后获取）
   - EN8801SC PHY 在 U-Boot 里的支持情况 → 待确认
2. uboot-mediatek/Makefile 新增条目（`BL2_DDRTYPE:=ddr3`, `BL2_BOOTDEV:=spim-nand`）
3. filogic.mk 设备条目加 ARTIFACTS

BL2 几乎不需要替换（设备已有 hanwckf BL2 正常工作）；主要工作是 U-Boot FIP。

## 重要约定

- **Git commit co-author**: `Co-Authored-By: bugwriter <noreply@wahlau.top>`
- **push 冲突**：直接 force push，不 rebase
- **WireGuard 相关包已移除**（`kmod-wireguard`、`wireguard-tools`、`luci-proto-wireguard`）
- Docker 相关：EMMC 设备才启用，MTK SPIM-NAND 设备不加

## 常见问题

**Q: MTK 设备为什么只编 3 个设备？**
`diy.sh` 第 0 节的白名单 sed 会过滤掉 `.config` 里其他 `CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_*` 行。

**Q: sx_7981r128 为什么要 CI 注入而不是直接 PR 到上游？**
VIKINGYFY/immortalwrt 上游没有这个设备，CI 在构建时动态注入 DTS + filogic.mk 条目。

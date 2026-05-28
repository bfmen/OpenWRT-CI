#!/bin/bash

# =======================================================
# [upstream-fix] 删除上游 immortalwrt 格式损坏的 globitel-bt-r320 patch
# 该 patch (immortalwrt commit a3105d3f, 2026-05-07) 在 line 162/218 处
# 相邻多个 `--- /dev/null` 块之间缺 `diff --git` file-boundary header，
# 用 patch(1) plaintext 模式 apply 时报 "malformed patch at line 162"，
# 导致所有 MT7981 u-boot variant (abt_asr3000 / sx_7981r128 等) 编译失败。
# 我们不用 globitel-bt-r320 设备，直接删除该 patch。
# 上游修复后此 hook 会自然 no-op（文件不存在则跳过）。
# =======================================================
BROKEN_UBOOT_PATCH="package/boot/uboot-mediatek/patches/472-add-globitel-bt-r320.patch"
if [ -f "$BROKEN_UBOOT_PATCH" ]; then
    echo "[upstream-fix] 删除格式损坏的 $BROKEN_UBOOT_PATCH"
    rm -f "$BROKEN_UBOOT_PATCH"
fi

# =======================================================
# [device-add] 注入 SX 7981R128 设备支持
# 该设备不在 VIKINGYFY/immortalwrt 源码中，需要本 CI 注入
# - DTS：Scripts/dts/mt7981b-sx-7981r128.dts
# - 设备条目：追加到 target/linux/mediatek/image/filogic.mk
# - 仅 MTK 平台需要，其他平台（IPQ60XX/IPQ807X/Rockchip/x86）无影响
# - FIP / BL2 / U-Boot 的构建在独立项目 https://github.com/ysuolmai/UBOOT-CI
#   这里只产 sysupgrade.bin，不掺和 U-Boot
# =======================================================
SX7981_DTS_SRC="${GITHUB_WORKSPACE}/Scripts/dts/mt7981b-sx-7981r128.dts"
SX7981_FILOGIC_MK="target/linux/mediatek/image/filogic.mk"

if [ -f "$SX7981_DTS_SRC" ] && [ -d "target/linux/mediatek/dts" ]; then
    echo "================================================================"
    echo "[device-add] 注入 SX 7981R128 设备支持..."

    # 1. 复制 DTS
    cp -f "$SX7981_DTS_SRC" target/linux/mediatek/dts/
    echo "[device-add]   DTS 已复制到 target/linux/mediatek/dts/"

    # 2. 追加设备到 filogic.mk（幂等：已存在则跳过）
    if [ -f "$SX7981_FILOGIC_MK" ] && ! grep -q '^define Device/sx_7981r128' "$SX7981_FILOGIC_MK"; then
        cat >> "$SX7981_FILOGIC_MK" << 'FILOGIC_EOF'

define Device/sx_7981r128
  DEVICE_VENDOR := SX
  DEVICE_MODEL := 7981R128
  DEVICE_DTS := mt7981b-sx-7981r128
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 \
                     kmod-sfp kmod-i2c-gpio
  # 第一项 = 新 DTS 的 compatible 第一字段（运行时 board_name）
  # 第二项 = hanwckf 老固件 board name，允许从老固件直接 sysupgrade 过来
  SUPPORTED_DEVICES := sx,7981r128 mediatek,mt7981-spim-snand-7981r128
  KERNEL_IN_UBI := 1
  UBOOTENV_IN_UBI := 1
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 65536k
  UBINIZE_OPTS := -E 5
  # sysupgrade.bin = sysupgrade-tar（OpenWrt 通用升级包），
  #                  既能在 OpenWrt 系统内 sysupgrade 升级，
  #                  也能被 hanwckf 改的 U-Boot HTTP recovery 接受
  IMAGES := sysupgrade.bin
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += sx_7981r128
FILOGIC_EOF
        echo "[device-add]   设备条目已追加到 filogic.mk"
    else
        echo "[device-add]   设备条目已存在，跳过追加"
    fi

    # 3. 注入 board.d/02_network 配置
    #    端口分配：lan1（千兆）→ br-lan，lan2（2.5G EN8801SC）→ WAN
    #    eth1（SFP 笼）通过 uci-defaults 配置为 wan2
    #    没有这个配置，OpenWrt 会走默认 *) 分支，端口不能正常工作
    BOARD_NETWORK="target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
    if [ -f "$BOARD_NETWORK" ] && ! grep -q 'sx,7981r128' "$BOARD_NETWORK"; then
        awk '
            !done && /^\t\*\)$/ {
                print "\tsx,7981r128)"
                print "\t\tucidef_set_interfaces_lan_wan \"lan1\" \"lan2\""
                print "\t\t;;"
                done = 1
            }
            { print }
        ' "$BOARD_NETWORK" > "$BOARD_NETWORK.new" && mv "$BOARD_NETWORK.new" "$BOARD_NETWORK"
        echo "[device-add]   02_network case 已注入"
    fi

    # 4. 注入首次启动 uci-defaults
    #    - 启用 WiFi（radio0/radio1 默认 disabled=1）
    #    - 添加 wan2 接口（eth1，SFP 笼，DHCP）并加入防火墙 WAN zone
    mkdir -p package/base-files/files/etc/uci-defaults
    cat > package/base-files/files/etc/uci-defaults/98_sx_7981r128_init.sh << 'UCI_EOF'
#!/bin/sh
# 仅对 sx,7981r128 执行
[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "sx,7981r128" ] || exit 0

# --- WiFi：启用双频射频 ---
uci set wireless.radio0.disabled=0
uci set wireless.radio1.disabled=0
uci commit wireless

# --- 网络：wan6（2.5G 主WAN，lan2，IPv6）+ wan2/wan2_6（SFP 笼，eth1）---
# wan6 不由 ucidef_set_interfaces_lan_wan 自动创建，需手动补上
uci set network.wan6=interface
uci set network.wan6.device=lan2
uci set network.wan6.proto=dhcpv6
uci set network.wan2=interface
uci set network.wan2.device=eth1
uci set network.wan2.proto=dhcp
uci set network.wan2_6=interface
uci set network.wan2_6.device=eth1
uci set network.wan2_6.proto=dhcpv6
uci commit network

# --- 防火墙：将 wan2 加入 WAN zone ---
wan_zone_idx=""
i=0
while uci get "firewall.@zone[$i]" >/dev/null 2>&1; do
    if [ "$(uci get firewall.@zone[$i].name 2>/dev/null)" = "wan" ]; then
        wan_zone_idx=$i
        break
    fi
    i=$((i + 1))
done
if [ -n "$wan_zone_idx" ]; then
    uci add_list firewall.@zone[$wan_zone_idx].network=wan2
    uci add_list firewall.@zone[$wan_zone_idx].network=wan2_6
    uci commit firewall
fi

# --- LED：green:lan (GPIO 8) 绑定到 2.5G 物理口 lan2 ---
# 实机点灯测试确认：green:lan 这颗物理 LED 位于 2.5G 网口旁
uci add system led
uci set system.@led[-1].name='led_lan2'
uci set system.@led[-1].sysfs='green:lan'
uci set system.@led[-1].trigger='netdev'
uci set system.@led[-1].dev='lan2'
uci set system.@led[-1].mode='link tx rx'
uci commit system

exit 0
UCI_EOF
    chmod +x package/base-files/files/etc/uci-defaults/98_sx_7981r128_init.sh
    echo "[device-add]   uci-defaults 98_sx_7981r128_init.sh 已注入"

    echo "[device-add] 完成"
    echo "================================================================"
fi

#安装和更新软件包
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	
	read -ra PKG_NAMES <<< "$PKG_NAME"
	for NAME in "${PKG_NAMES[@]}"; do
		find feeds/luci/ feeds/packages/ package/ -maxdepth 3 -type d \( -name "$NAME" -o -name "luci-*-$NAME" \) -exec rm -rf {} + 2>/dev/null
	done
	
	if [[ $PKG_REPO == http* ]]; then
		local REPO_NAME=$(basename "$PKG_REPO" .git)
	else
		local REPO_NAME=$(echo "$PKG_REPO" | cut -d '/' -f 2)
		PKG_REPO="https://github.com/$PKG_REPO.git"
	fi
	
	if ! git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "$PKG_REPO" "package/$REPO_NAME"; then
		echo "错误: 克隆仓库失败 $PKG_REPO"
		return 1
	fi
	
	case "$PKG_SPECIAL" in
		"pkg")
			for NAME in "${PKG_NAMES[@]}"; do
				find "./package/$REPO_NAME" -maxdepth 3 -type d \( -name "$NAME" -o -name "luci-*-$NAME" \) -print0 | \
					xargs -0 -I {} cp -rf {} ./package/ 2>/dev/null
			done
			rm -rf "./package/$REPO_NAME/"
			;;
		"name")
			rm -rf "./package/$PKG_NAME"
			mv -f "./package/$REPO_NAME" "./package/$PKG_NAME"
			;;
	esac
}

UPDATE_PACKAGE "luci-app-poweroff" "esirplayground/luci-app-poweroff" "main"
UPDATE_PACKAGE "luci-app-tailscale" "asvow/luci-app-tailscale" "main"
UPDATE_PACKAGE "openwrt-gecoosac" "ysuolmai/openwrt-gecoosac" "main"
# gecoosac 上游作者 (kiss19776) 经常覆盖同名 release asset，PKG_HASH 跟不上
# 把 PKG_HASH:=xxxxx 改成 PKG_HASH:=skip 跳过校验
if [ -f ./package/openwrt-gecoosac/gecoosac/Makefile ]; then
    sed -i 's/^PKG_HASH:=.*/PKG_HASH:=skip/' ./package/openwrt-gecoosac/gecoosac/Makefile
    echo "[diy] openwrt-gecoosac PKG_HASH 设为 skip"
fi
UPDATE_PACKAGE "luci-app-openlist2" "sbwml/luci-app-openlist2" "main"

#small-package
UPDATE_PACKAGE "xray-core xray-plugin dns2tcp dns2socks haproxy hysteria \
        naiveproxy v2ray-core v2ray-geodata v2ray-geoview v2ray-plugin \
        tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev \
        luci-app-passwall smartdns luci-app-smartdns v2dat mosdns luci-app-mosdns \
        taskd luci-lib-xterm luci-lib-taskd luci-app-passwall2 \
        luci-app-store quickstart luci-app-quickstart luci-app-istorex luci-app-cloudflarespeedtest \
        luci-theme-argon netdata luci-app-netdata lucky luci-app-lucky luci-app-openclash mihomo \
        luci-app-nikki frp luci-app-ddns-go ddns-go docker dockerd" "kenzok8/jell" "main" "pkg"

#speedtest
UPDATE_PACKAGE "luci-app-netspeedtest" "https://github.com/sbwml/openwrt_pkgs.git" "main" "pkg"
UPDATE_PACKAGE "speedtest-cli" "https://github.com/sbwml/openwrt_pkgs.git" "main" "pkg"

UPDATE_PACKAGE "luci-app-adguardhome" "https://github.com/ysuolmai/luci-app-adguardhome.git" "apk"
UPDATE_PACKAGE "luci-app-tailscale" "asvow/luci-app-tailscale" "main"

UPDATE_PACKAGE "openwrt-podman" "https://github.com/breeze303/openwrt-podman" "main"
UPDATE_PACKAGE "luci-app-quickfile" "https://github.com/sbwml/luci-app-quickfile" "main"
sed -i 's|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-$(ARCH_PACKAGES) $(1)/usr/bin/quickfile|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-aarch64_generic $(1)/usr/bin/quickfile|' package/luci-app-quickfile/quickfile/Makefile

# bandix
UPDATE_PACKAGE "openwrt-bandix" "timsaya/openwrt-bandix" "main"
UPDATE_PACKAGE "luci-app-bandix" "timsaya/luci-app-bandix" "main"

UPDATE_PACKAGE "luci-theme-shadcn" "ysuolmai/luci-theme-shadcn" "main"


#######################################
#DIY Settings
#######################################
WRT_IP="192.168.1.1"
WRT_NAME="FWRT"
WRT_WIFI="FWRT"

sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh")
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE


if [[ $WRT_CONFIG == *"EMMC"* ]]; then
    keep_pattern="\(redmi_ax5-jdcloud\|jdcloud_re-ss-01\|jdcloud_re-cs-07\)=y$"
else
    keep_pattern="\(redmi_ax5\|qihoo_360v6\|redmi_ax5-jdcloud\|zn_m2\|jdcloud_re-ss-01\|jdcloud_re-cs-07\)=y$"
fi

sed -i "/^CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_/{
    /$keep_pattern/!d
}" ./.config


# MTK 设备白名单——只保留这里列出的设备，其他 MEDIATEK-WIFI-{YES,NO}.txt
# 里的设备一律从 .config 删掉，避免无意义编译。
# 想多编几个设备就往 mtk_keep 里加（用 \| 分隔），名字对应
# Config/MEDIATEK-WIFI-*.txt 里 CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_xxx 的 xxx。
mtk_keep="\(sx_7981r128\|nokia_ea0326gmp\|cmcc_rax3000m\)=y$"

sed -i "/^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_/{
    /$mtk_keep/!d
}" ./.config


keywords_to_delete=(
    "uugamebooster" "luci-app-wol" "luci-i18n-wol-zh-cn" "CONFIG_TARGET_INITRAMFS" "ddns" "luci-app-advancedplus" "mihomo" "nikki"
    "smartdns" "kucat" "bootstrap" "luci-app-partexp" "luci-app-upnp"
)

[[ $WRT_CONFIG == *"WIFI-NO"* ]] && keywords_to_delete+=("usb" "wpad" "hostapd")
[[ $WRT_CONFIG != *"EMMC"* ]] && keywords_to_delete+=("samba" "autosamba" "disk")

for keyword in "${keywords_to_delete[@]}"; do
    sed -i "/$keyword/d" ./.config
done

provided_config_lines=(
    "CONFIG_PACKAGE_luci-app-zerotier=y"
    "CONFIG_PACKAGE_luci-i18n-zerotier-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-adguardhome=y"
    "CONFIG_PACKAGE_luci-i18n-adguardhome-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-poweroff=y"
    "CONFIG_PACKAGE_luci-i18n-poweroff-zh-cn=y"
    "CONFIG_PACKAGE_cpufreq=y"
    "CONFIG_PACKAGE_luci-app-cpufreq=y"
    "CONFIG_PACKAGE_luci-i18n-cpufreq-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-ttyd=y"
    "CONFIG_PACKAGE_luci-i18n-ttyd-zh-cn=y"
    "CONFIG_PACKAGE_ttyd=y"
    "CONFIG_PACKAGE_luci-app-homeproxy=y"
    "CONFIG_PACKAGE_luci-i18n-homeproxy-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-ddns-go=y"
    "CONFIG_PACKAGE_luci-i18n-ddns-go-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-argon-config=y"
    "CONFIG_PACKAGE_nano=y"
    "CONFIG_PACKAGE_luci-app-netspeedtest=y"
    "CONFIG_PACKAGE_luci-app-vlmcsd=y"
    "CONFIG_COREMARK_OPTIMIZE_O3=y"
    "CONFIG_COREMARK_ENABLE_MULTITHREADING=y"
    "CONFIG_COREMARK_NUMBER_OF_THREADS=6"
    "CONFIG_PACKAGE_luci-app-filetransfer=y"
    "CONFIG_PACKAGE_openssh-sftp-server=y"
    "CONFIG_PACKAGE_luci-app-frpc=y"
    "CONFIG_OPKG_USE_CURL=y"
    "CONFIG_PACKAGE_opkg=y"
    "CONFIG_USE_APK=n"
    "CONFIG_PACKAGE_luci-app-tailscale=y"
    "CONFIG_PACKAGE_luci-app-gecoosac=y"
    "CONFIG_PACKAGE_luci-app-cifs-mount=y"
    "CONFIG_PACKAGE_kmod-fs-cifs=y"
    "CONFIG_PACKAGE_cifsmount=y"
	"CONFIG_PACKAGE_luci-theme-shadcn=y"
)

if [[ $WRT_CONFIG == *"WIFI-NO"* ]]; then
    provided_config_lines+=("CONFIG_PACKAGE_hostapd-common=n" "CONFIG_PACKAGE_wpad-openssl=n")
fi

if [[ "$WRT_CONFIG" != *"EMMC"* && "$WRT_CONFIG" == *"WIFI-NO"* ]]; then
    sed -i 's/\s*kmod-[^ ]*usb[^ ]*\s*\\\?//g' ./target/linux/qualcommax/Makefile
    echo "已删除 Makefile 中的 USB 相关 package"
fi

[[ $WRT_CONFIG == *"EMMC"* ]] && provided_config_lines+=(
    "CONFIG_PACKAGE_luci-app-docker=y"
    "CONFIG_PACKAGE_luci-i18n-docker-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-dockerman=y"
    "CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-openlist2=y"
    "CONFIG_PACKAGE_luci-i18n-openlist2-zh-cn=y"
    "CONFIG_PACKAGE_ip6tables-nft=y"
    "CONFIG_PACKAGE_luci-app-passwall=y"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Client=y"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Server=y"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Client=n"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Simple_Obfs=n"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox=n"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Trojan_Plus=n"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Plugin=n"
    "CONFIG_PACKAGE_htop=y"
    "CONFIG_PACKAGE_tcpdump=y"
    "CONFIG_PACKAGE_openssl-util=y"
    "CONFIG_PACKAGE_qrencode=y"
    "CONFIG_PACKAGE_smartmontools-drivedb=y"
    "CONFIG_PACKAGE_default-settings=y"
    "CONFIG_PACKAGE_default-settings-chn=y"
    "CONFIG_PACKAGE_kmod-br-netfilter=y"
    "CONFIG_PACKAGE_kmod-nf-ipt6=y"
    "CONFIG_PACKAGE_kmod-nf-ipvs=y"
    "CONFIG_PACKAGE_kmod-nf-nat6=y"
    "CONFIG_PACKAGE_kmod-dummy=y"
    "CONFIG_PACKAGE_kmod-veth=y"
    "CONFIG_PACKAGE_luci-app-frps=y"
    "CONFIG_PACKAGE_luci-app-samba4=y"
    "CONFIG_PACKAGE_luci-app-openclash=y"
    "CONFIG_PACKAGE_libuver-zero=y"
    "CONFIG_PACKAGE_kmod-sched-tbf=y"
    "CONFIG_PACKAGE_kmod-sched-htb=y"
    "CONFIG_PACKAGE_tc-full=y"
    "CONFIG_PACKAGE_kmod-sched-netem=y"
)

[[ $WRT_CONFIG == "IPQ"* ]] && provided_config_lines+=(
    "CONFIG_PACKAGE_sqm-scripts-nss=y"
    "CONFIG_PACKAGE_luci-app-sqm=y"
    "CONFIG_PACKAGE_luci-i18n-sqm-zh-cn=y"
)

for line in "${provided_config_lines[@]}"; do
    echo "$line" >> .config
done

# =======================================================
# [pkg-fix] 替换 Makefile 中的 +kmod-iptables 直接依赖为 +kmod-nf-ipt
# =======================================================
echo "================================================================"
echo "[pkg-fix] 替换 Makefile 中的 +kmod-iptables 依赖为 +kmod-nf-ipt"

_affected=$(grep -rl "+kmod-iptables" package/ feeds/ 2>/dev/null || true)
if [ -n "$_affected" ]; then
    _total=$(echo "$_affected" | wc -l)
    echo "[pkg-fix] 发现 $_total 个文件依赖 kmod-iptables，前 15 个:"
    echo "$_affected" | head -15 | sed 's/^/  - /'
    while IFS= read -r _mk; do
        sed -i -E 's/\+kmod-iptables([^a-zA-Z0-9_-]|$)/+kmod-nf-ipt\1/g' "$_mk"
    done <<< "$_affected"
    _remain=$(grep -rlE "\+kmod-iptables([^a-zA-Z0-9_-]|$)" package/ feeds/ 2>/dev/null | wc -l)
    echo "[pkg-fix] 替换完成，残留 $_remain 处 (应为 0)"
else
    echo "[pkg-fix] 没有文件依赖 kmod-iptables (已是干净状态)"
fi

sed -i '/^CONFIG_PACKAGE_kmod-iptables=/d' .config
echo '# CONFIG_PACKAGE_kmod-iptables is not set' >> .config
echo "================================================================"

# =======================================================
# [pkg-fix-2] 替换 Makefile 中 +iptables 间接依赖为 +iptables-nft
# =======================================================
echo "================================================================"
echo "[pkg-fix-2] 替换 Makefile 中的 +iptables 间接依赖为 +iptables-nft"

_affected2=$(grep -rlE '\+iptables([^-a-zA-Z0-9_]|$)' package/ feeds/ 2>/dev/null \
    | xargs grep -lv 'PKG_NAME:=iptables' 2>/dev/null || true)

if [ -n "$_affected2" ]; then
    _total2=$(echo "$_affected2" | wc -l)
    echo "[pkg-fix-2] 发现 $_total2 个文件依赖 +iptables，前 15 个:"
    echo "$_affected2" | head -15 | sed 's/^/  - /'
    while IFS= read -r _mk; do
        sed -i -E 's/\+iptables([^-a-zA-Z0-9_]|$)/+iptables-nft\1/g' "$_mk"
    done <<< "$_affected2"
    _remain2=$(grep -rlE '\+iptables([^-a-zA-Z0-9_]|$)' package/ feeds/ 2>/dev/null \
        | xargs grep -lv 'PKG_NAME:=iptables' 2>/dev/null | wc -l)
    echo "[pkg-fix-2] 替换完成，残留 $_remain2 处 (应为 0)"
else
    echo "[pkg-fix-2] 没有文件依赖 +iptables (已是干净状态)"
fi

sed -i '/^CONFIG_PACKAGE_iptables=/d' .config
echo '# CONFIG_PACKAGE_iptables is not set' >> .config
echo "================================================================"

# =======================================================
# [pkg-fix-3] 清除 kmod-iptables 的文件安装，消除与 kmod-nf-ipt 的冲突
# 根因：内核 CONFIG_IP_NF_IPTABLES=m 会让构建系统自动选中 kmod-iptables，
# 绕过 Makefile 依赖链。让 kmod-iptables 变成不安装任何文件的空壳包，
# 由 kmod-nf-ipt 提供相同的 .ko，功能不受影响，冲突消失。
# =======================================================
echo "================================================================"
echo "[pkg-fix-3] 清除 kmod-iptables FILES/AUTOLOAD，消除与 kmod-nf-ipt 的文件冲突"

KMOD_IPT_MK=$(grep -rl "define KernelPackage/iptables$" package/ target/ 2>/dev/null | head -n 1)
if [ -n "$KMOD_IPT_MK" ]; then
    echo "[pkg-fix-3] 找到定义文件: $KMOD_IPT_MK"
    python3 - "$KMOD_IPT_MK" << 'PYEOF'
import sys

filename = sys.argv[1]
with open(filename) as f:
    lines = f.readlines()

result = []
in_ipt_block = False
skip_continuation = False

for line in lines:
    stripped = line.strip()

    if stripped == 'define KernelPackage/iptables':
        in_ipt_block = True
        result.append(line)
        continue

    if in_ipt_block and stripped == 'endef':
        in_ipt_block = False
        result.append(line)
        continue

    if in_ipt_block:
        if skip_continuation:
            if not stripped.endswith('\\'):
                skip_continuation = False
            continue
        if stripped.startswith('FILES:=') or stripped.startswith('AUTOLOAD:='):
            if stripped.endswith('\\'):
                skip_continuation = True
            continue

    result.append(line)

with open(filename, 'w') as f:
    f.writelines(result)

print(f'[pkg-fix-3] 完成: {filename}')
PYEOF
else
    echo "[pkg-fix-3] 未找到 kmod-iptables 定义文件，跳过"
fi
echo "================================================================"


find ./ -name "cascade.css" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;
find ./ -name "dark.css" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;
find ./ -name "cascade.less" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;
find ./ -name "dark.less" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;

install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_ttyd-nopass.sh" "package/base-files/files/etc/uci-defaults/99_ttyd-nopass"
install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_set_argon_primary" "package/base-files/files/etc/uci-defaults/99_set_argon_primary"

install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99-distfeeds.conf" "package/emortal/default-settings/files/99-distfeeds.conf"
sed -i '/define Package\/default-settings\/install/a \
\t$(INSTALL_DIR) $(1)/etc\n\t$(INSTALL_DATA) ./files/99-distfeeds.conf $(1)/etc/99-distfeeds.conf' \
package/emortal/default-settings/Makefile

sed -i "/exit 0/i\\
[ -f \'/etc/99-distfeeds.conf\' ] && mv \'/etc/99-distfeeds.conf\' \'/etc/opkg/distfeeds.conf\'\n\
sed -ri \'/check_signature/s@^[^#]@#&@\' /etc/opkg.conf\n" "package/emortal/default-settings/files/99-default-settings"

install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_dropbear_setup.sh" "package/base-files/files/etc/uci-defaults/99_dropbear_setup"

find ./ -name "getifaddr.c" -exec sed -i 's/return 1;/return 0;/g' {} \;

if [ -f ./package/v2ray-geodata/Makefile ]; then
    sed -i 's/VER)-\$(PKG_RELEASE)/VER)-r\$(PKG_RELEASE)/g' ./package/v2ray-geodata/Makefile
fi
if [ -f ./package/luci-lib-taskd/Makefile ]; then
    sed -i 's/>=1\.0\.3-1/>=1\.0\.3-r1/g' ./package/luci-lib-taskd/Makefile
fi
if [ -f ./package/luci-app-openclash/Makefile ]; then
    sed -i '/^PKG_VERSION:=/a PKG_RELEASE:=1' ./package/luci-app-openclash/Makefile
fi
if [ -f ./package/luci-app-quickstart/Makefile ]; then
    sed -i -E 's/PKG_VERSION:=([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)/PKG_VERSION:=\1\nPKG_RELEASE:=\2/' ./package/luci-app-quickstart/Makefile
fi
if [ -f ./package/luci-app-store/Makefile ]; then
    sed -i -E 's/PKG_VERSION:=([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)/PKG_VERSION:=\1\nPKG_RELEASE:=\2/' ./package/luci-app-store/Makefile
fi

if [ -f ./package/luci-app-ddns-go/ddns-go/file/ddns-go.init ]; then
    cp ${GITHUB_WORKSPACE}/Scripts/ddns-go.init ./package/luci-app-ddns-go/ddns-go/file/ddns-go.init
    chmod +x ./package/luci-app-ddns-go/ddns-go/file/ddns-go.init
    echo "ddns-go.init has been replaced successfully."
fi

RUST_FILE=$(find ./feeds/packages/ -maxdepth 3 -type f -wholename "*/rust/Makefile")
if [ -f "$RUST_FILE" ]; then
    echo " "
    sed -i 's/ci-llvm=true/ci-llvm=false/g' $RUST_FILE
    patch $RUST_FILE ${GITHUB_WORKSPACE}/Scripts/rust-makefile.patch
    echo "rust has been fixed!"
fi


# =======================================================
# 解决 opkg 报错：正确补齐 dockerman 及其依赖
# =======================================================
echo "Handling Docker dependencies..."

rm -rf package/feeds/luci/luci-app-dockerman
rm -rf package/feeds/luci/luci-lib-docker
rm -rf package/luci-app-dockerman
rm -rf package/luci-lib-docker

echo "Cloning luci-app-dockerman..."
git clone --depth 1 https://github.com/lisaac/luci-app-dockerman.git temp_dockerman
mv temp_dockerman/applications/luci-app-dockerman package/luci-app-dockerman
rm -rf temp_dockerman

echo "Cloning luci-lib-docker..."
git clone --depth 1 https://github.com/lisaac/luci-lib-docker.git temp_libdocker
if [ -d "temp_libdocker/collections/luci-lib-docker" ]; then
    mv temp_libdocker/collections/luci-lib-docker package/luci-lib-docker
else
    mv temp_libdocker package/luci-lib-docker
fi
rm -rf temp_libdocker

if [ -f "package/luci-app-dockerman/Makefile" ]; then
    echo "Removing cgroupfs-mount dependency..."
    sed -i 's/+cgroupfs-mount //g' package/luci-app-dockerman/Makefile
    sed -i 's/+cgroupfs-mount//g' package/luci-app-dockerman/Makefile
fi

./scripts/feeds install ttyd
./scripts/feeds install luci-lib-docker

# =======================================================
# 修复 Docker 引擎 (dockerd) 和 CLI (docker)
# =======================================================
echo "Fetching latest Docker version..."
_MOBY_TAG=$(curl -sf https://api.github.com/repos/moby/moby/releases/latest | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
DOCKER_VER=$(echo "$_MOBY_TAG" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

if [ -z "$DOCKER_VER" ]; then
    echo "警告: 无法获取 Docker 最新版本，回退到 29.5.2"
    DOCKER_VER="29.5.2"
    DOCKERD_COMMIT="568f755"
    DOCKER_CLI_COMMIT="79eb04c"
else
    echo "Latest Docker version: $DOCKER_VER (tag: $_MOBY_TAG)"
    DOCKERD_COMMIT=$(curl -sf "https://api.github.com/repos/moby/moby/commits?sha=${_MOBY_TAG}&per_page=1" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['sha'][:7] if isinstance(d,list) and d else '')")
    DOCKER_CLI_COMMIT=$(curl -sf "https://api.github.com/repos/docker/cli/commits?sha=v${DOCKER_VER}&per_page=1" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['sha'][:7] if isinstance(d,list) and d else '')")
    if [ -z "$DOCKERD_COMMIT" ] || [ -z "$DOCKER_CLI_COMMIT" ]; then
        echo "警告: 无法获取 commit hash，回退到已知值"
        DOCKERD_COMMIT="568f755"
        DOCKER_CLI_COMMIT="79eb04c"
    fi
fi
echo "Docker: $DOCKER_VER | dockerd: $DOCKERD_COMMIT | cli: $DOCKER_CLI_COMMIT"

dockerd_makefile=$(find package/ feeds/ -name Makefile | xargs grep -lE "^PKG_NAME:=dockerd$" | head -n 1)
docker_makefile=$(find package/ feeds/ -name Makefile | xargs grep -lE "^PKG_NAME:=docker$" | head -n 1)

if [ -f "$dockerd_makefile" ]; then
    echo "Processing dockerd Makefile at: $dockerd_makefile"
    sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$DOCKER_VER/" "$dockerd_makefile"
    sed -i "s/PKG_GIT_SHORT_COMMIT:=.*/PKG_GIT_SHORT_COMMIT:=$DOCKERD_COMMIT/g" "$dockerd_makefile"
    sed -i 's/^PKG_HASH:=.*/PKG_HASH:=skip/' "$dockerd_makefile"
    sed -i '/define Build\/Prepare/,/endef/c\define Build\/Prepare\n\t$(Build\/Prepare\/Default)\nendef' "$dockerd_makefile"
    sed -i 's/^\t$(call EnsureVendored/#\t$(call EnsureVendored/g' "$dockerd_makefile"
fi

if [ -f "$docker_makefile" ]; then
    echo "Processing docker CLI Makefile at: $docker_makefile"
    sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$DOCKER_VER/" "$docker_makefile"
    sed -i "s/PKG_GIT_SHORT_COMMIT:=.*/PKG_GIT_SHORT_COMMIT:=$DOCKER_CLI_COMMIT/g" "$docker_makefile"
    sed -i 's/^PKG_HASH:=.*/PKG_HASH:=skip/' "$docker_makefile"
    sed -i '/define Build\/Prepare/,/endef/c\define Build\/Prepare\n\t$(Build\/Prepare\/Default)\nendef' "$docker_makefile"
fi

echo "All Docker compilation fixes applied successfully!"


if ! grep -q "CMAKE_POLICY_VERSION_MINIMUM" include/cmake.mk; then
    echo 'CMAKE_OPTIONS += -DCMAKE_POLICY_VERSION_MINIMUM=3.5' >> include/cmake.mk
fi

# 升级 golang 到支持 go.mod >= 1.26 的版本
WRT_DIR=$(pwd)
rm -rf feeds/packages/lang/golang
git clone https://github.com/openwrt/packages --depth=1 --filter=blob:none --sparse /tmp/openwrt-packages
cd /tmp/openwrt-packages && git sparse-checkout set lang/golang
cp -r /tmp/openwrt-packages/lang/golang "$WRT_DIR/feeds/packages/lang/golang"
cd "$WRT_DIR"
./scripts/feeds install golang

# =======================================================
# [kernel-fix] 修复 Linux 6.18 新增 Kconfig 选项
# 导致 syncconfig 在 CI 非交互环境下卡死报错
# 遇到新的 (NEW) 选项，往 NEW_OPTS 数组里加一行即可
# =======================================================
NEW_OPTS=(
    "PERSISTENT_HUGE_ZERO_FOLIO"
    "NO_PAGE_MAPCOUNT"
)

echo "[kernel-fix] 开始修复新增 Kconfig 选项..."

while IFS= read -r -d '' cfg; do
    for opt in "${NEW_OPTS[@]}"; do
        if ! grep -q "CONFIG_${opt}" "$cfg"; then
            echo "# CONFIG_${opt} is not set" >> "$cfg"
            echo "[kernel-fix] 已追加 # CONFIG_${opt} is not set -> $cfg"
        fi
    done
done < <(find target/linux/generic/ target/linux/qualcommax/ -name "config-*" -print0 2>/dev/null)

echo "[kernel-fix] 完成。"

# =======================================================
# [dae] DAE 构建专项处理
# 仅当 WRT_CONFIG 含 "DAE" 时执行，不影响其他任何构建
# =======================================================
if [[ "$WRT_CONFIG" == *"DAE"* ]]; then
    echo "================================================================"
    echo "[dae] 开始 DAE 构建专项配置..."

    # 0. 从独立仓库拉取 dae + luci-app-dae 包
    #    仓库：https://github.com/ysuolmai/luci-app-dae
    #    这两个包独立维护，便于版本升级和复用，不污染主仓库
    DAE_FEED_DIR="/tmp/luci-app-dae-feed"
    rm -rf "$DAE_FEED_DIR"
    if git clone --depth=1 https://github.com/ysuolmai/luci-app-dae "$DAE_FEED_DIR"; then
        rm -rf package/dae package/luci-app-dae
        cp -rf "$DAE_FEED_DIR/dae"          package/
        cp -rf "$DAE_FEED_DIR/luci-app-dae" package/
        echo "[dae] 已从 ysuolmai/luci-app-dae 拉取 dae + luci-app-dae"
    else
        echo "[dae] 警告：clone luci-app-dae 失败，跳过（构建将失败）"
    fi

    # 1. 移除 openclash 和 passwall（dae 是唯一透明代理，避免冲突）
    sed -i '/openclash/d; /passwall/d' .config
    echo "[dae] 已从 .config 移除 openclash / passwall 相关行"

    # 2. 扩大 eMMC 设备内核分区
    #    dae 包含 eBPF 字节码，编译产物比普通代理大，默认 6144k 不够
    image_file='./target/linux/qualcommax/image/ipq60xx.mk'
    if [ -f "$image_file" ]; then
        sed -i "/^define Device\/emmc-common/,/^endef/ s/KERNEL_SIZE := 6144k/KERNEL_SIZE := 12288k/" "$image_file"
        sed -i "/^define Device\/jdcloud_re-ss-01/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" "$image_file"
        sed -i "/^define Device\/jdcloud_re-cs-02/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" "$image_file"
        sed -i "/^define Device\/jdcloud_re-cs-07/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" "$image_file"
        sed -i "/^define Device\/link_nn6000-common/,/^endef/ { /KERNEL_SIZE := 6144k/s//KERNEL_SIZE := 12288k/ }" "$image_file"
        sed -i "/^define Device\/linksys_mr/,/^endef/ { /KERNEL_SIZE := 8192k/s//KERNEL_SIZE := 12288k/ }" "$image_file"
        echo "[dae] eMMC 内核分区已扩大至 12288k"
    fi

    echo "[dae] DAE 构建专项配置完成"
    echo "================================================================"
fi

#!/bin/bash

#安装和更新软件包
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	
	# 清理旧的包(更精确的匹配)
	read -ra PKG_NAMES <<< "$PKG_NAME"
	for NAME in "${PKG_NAMES[@]}"; do
		# 使用更精确的匹配,避免误删
		find feeds/luci/ feeds/packages/ package/ -maxdepth 3 -type d \( -name "$NAME" -o -name "luci-*-$NAME" \) -exec rm -rf {} + 2>/dev/null
	done
	
	# 克隆仓库
	if [[ $PKG_REPO == http* ]]; then
		local REPO_NAME=$(basename "$PKG_REPO" .git)
	else
		local REPO_NAME=$(echo "$PKG_REPO" | cut -d '/' -f 2)
		PKG_REPO="https://github.com/$PKG_REPO.git"
	fi
	
	# 检查是否克隆成功
	if ! git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "$PKG_REPO" "package/$REPO_NAME"; then
		echo "错误: 克隆仓库失败 $PKG_REPO"
		return 1
	fi
	
	# 根据 PKG_SPECIAL 处理包
	case "$PKG_SPECIAL" in
		"pkg")
			for NAME in "${PKG_NAMES[@]}"; do
				# 从仓库根目录搜索,不限制路径结构
				find "./package/$REPO_NAME" -maxdepth 3 -type d \( -name "$NAME" -o -name "luci-*-$NAME" \) -print0 | \
					xargs -0 -I {} cp -rf {} ./package/ 2>/dev/null
			done
			rm -rf "./package/$REPO_NAME/"
			;;
		"name")
			# 避免重命名冲突
			rm -rf "./package/$PKG_NAME"
			mv -f "./package/$REPO_NAME" "./package/$PKG_NAME"
			;;
	esac
}

UPDATE_PACKAGE "luci-app-poweroff" "esirplayground/luci-app-poweroff" "main"
UPDATE_PACKAGE "luci-app-tailscale" "asvow/luci-app-tailscale" "main"
UPDATE_PACKAGE "openwrt-gecoosac" "lwb1978/openwrt-gecoosac" "main"
#UPDATE_PACKAGE "luci-app-homeproxy" "immortalwrt/homeproxy" "master"
#UPDATE_PACKAGE "luci-app-ddns-go" "sirpdboy/luci-app-ddns-go" "main"
#UPDATE_PACKAGE "luci-app-alist" "sbwml/luci-app-alist" "main"
UPDATE_PACKAGE "luci-app-openlist2" "sbwml/luci-app-openlist2" "main"

#small-package
UPDATE_PACKAGE "xray-core xray-plugin dns2tcp dns2socks haproxy hysteria \
        naiveproxy v2ray-core v2ray-geodata v2ray-geoview v2ray-plugin \
        tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev \
        luci-app-passwall smartdns luci-app-smartdns v2dat mosdns luci-app-mosdns \
        taskd luci-lib-xterm luci-lib-taskd luci-app-passwall2 \
        luci-app-store quickstart luci-app-quickstart luci-app-istorex luci-app-cloudflarespeedtest \
        luci-theme-argon netdata luci-app-netdata lucky luci-app-lucky luci-app-openclash mihomo \
        luci-app-nikki frp luci-app-ddns-go ddns-go docker dockerd" "kenzok8/small-package" "main" "pkg"

#speedtest
UPDATE_PACKAGE "luci-app-netspeedtest" "https://github.com/sbwml/openwrt_pkgs.git" "main" "pkg"
UPDATE_PACKAGE "speedtest-cli" "https://github.com/sbwml/openwrt_pkgs.git" "main" "pkg"

UPDATE_PACKAGE "luci-app-adguardhome" "https://github.com/ysuolmai/luci-app-adguardhome.git" "apk"
UPDATE_PACKAGE "luci-app-tailscale" "asvow/luci-app-tailscale" "main"

UPDATE_PACKAGE "openwrt-podman" "https://github.com/breeze303/openwrt-podman" "main"
UPDATE_PACKAGE "luci-app-quickfile" "https://github.com/sbwml/luci-app-quickfile" "main"
sed -i 's|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-$(ARCH_PACKAGES) $(1)/usr/bin/quickfile|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-aarch64_generic $(1)/usr/bin/quickfile|' package/luci-app-quickfile/quickfile/Makefile

#UPDATE_PACKAGE "frp" "https://github.com/ysuolmai/openwrt-frp.git" "main"

# bandix
UPDATE_PACKAGE "openwrt-bandix" "timsaya/openwrt-bandix" "main"
UPDATE_PACKAGE "luci-app-bandix" "timsaya/luci-app-bandix" "main"


#######################################
#DIY Settings
#######################################
WRT_IP="192.168.1.1"
WRT_NAME="FWRT"
WRT_WIFI="FWRT"
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh")
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	#修改WIFI加密
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE


#补齐依赖
#sudo -E apt-get -y install $(curl -fsSL https://raw.githubusercontent.com/ophub/amlogic-s9xxx-armbian/main/compile-kernel/tools/script/ubuntu2204-make-openwrt-depends)

# 只保留指定的 qualcommax_ipq60xx 设备
if [[ $WRT_CONFIG == *"EMMC"* ]]; then
    # 有 EMMC 时，只保留：redmi_ax5-jdcloud / jdcloud_re-ss-01 / jdcloud_re-cs-07
    keep_pattern="\(redmi_ax5-jdcloud\|jdcloud_re-ss-01\|jdcloud_re-cs-07\)=y$"
else
    # 普通情况，只保留这几个
    keep_pattern="\(redmi_ax5\|qihoo_360v6\|redmi_ax5-jdcloud\|zn_m2\|jdcloud_re-ss-01\|jdcloud_re-cs-07\)=y$"
fi

sed -i "/^CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_/{
    /$keep_pattern/!d
}" ./.config


keywords_to_delete=(
    #"xiaomi_ax3600" "xiaomi_ax9000" "xiaomi_ax1800" "glinet" "jdcloud_ax6600" "linksys" "link_nn6600" "re-cs-02" "nn6600" "mr7350"
    "uugamebooster" "luci-app-wol" "luci-i18n-wol-zh-cn" "CONFIG_TARGET_INITRAMFS" "ddns" "luci-app-advancedplus" "mihomo" "nikki"
    "smartdns" "kucat" "bootstrap" "kucat" "luci-app-partexp" "luci-app-upnp"
)

[[ $WRT_CONFIG == *"WIFI-NO"* ]] && keywords_to_delete+=("usb" "wpad" "hostapd")
[[ $WRT_CONFIG != *"EMMC"* ]] && keywords_to_delete+=("samba" "autosamba" "disk")

for keyword in "${keywords_to_delete[@]}"; do
    sed -i "/$keyword/d" ./.config
done

# Configuration lines to append to .config
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
    #"CONFIG_BUSYBOX_CONFIG_LSUSB=n"
    "CONFIG_PACKAGE_luci-app-netspeedtest=y"
    "CONFIG_PACKAGE_luci-app-vlmcsd=y"
    "CONFIG_COREMARK_OPTIMIZE_O3=y"
    "CONFIG_COREMARK_ENABLE_MULTITHREADING=y"
    "CONFIG_COREMARK_NUMBER_OF_THREADS=6"
    #"CONFIG_PACKAGE_luci-theme-design=y"
    "CONFIG_PACKAGE_luci-app-filetransfer=y"
    "CONFIG_PACKAGE_openssh-sftp-server=y"
    "CONFIG_PACKAGE_luci-app-frpc=y" 
    "CONFIG_OPKG_USE_CURL=y"
    "CONFIG_PACKAGE_opkg=y"   
    "CONFIG_USE_APK=n"
    "CONFIG_PACKAGE_luci-app-tailscale=y"
    #"CONFIG_PACKAGE_luci-app-msd_lite=y"
    #"CONFIG_PACKAGE_luci-app-lucky=y"
    "CONFIG_PACKAGE_luci-app-gecoosac=y"
	"CONFIG_PACKAGE_kmod-wireguard=y"
    "CONFIG_PACKAGE_wireguard-tools=y"
	"CONFIG_PACKAGE_luci-proto-wireguard=y"
    "CONFIG_PACKAGE_luci-app-cifs-mount=y"
	"CONFIG_PACKAGE_kmod-fs-cifs=y"
    "CONFIG_PACKAGE_cifsmount=y"
)

#[[ $WRT_CONFIG == *"WIFI-NO"* ]] && provided_config_lines+=("CONFIG_PACKAGE_hostapd-common=n" "CONFIG_PACKAGE_wpad-openssl=n")
if [[ $WRT_CONFIG == *"WIFI-NO"* ]]; then
  provided_config_lines+=("CONFIG_PACKAGE_hostapd-common=n" "CONFIG_PACKAGE_wpad-openssl=n")
fi


# 只有 WRT_CONFIG 不包含 'EMMC' 且包含 'WIFI-NO' 时执行删除命令
if [[ "$WRT_CONFIG" != *"EMMC"* && "$WRT_CONFIG" == *"WIFI-NO"* ]]; then
    sed -i 's/\s*kmod-[^ ]*usb[^ ]*\s*\\\?//g' ./target/linux/qualcommax/Makefile
    echo "已删除 Makefile 中的 USB 相关 package"
fi

[[ $WRT_CONFIG == *"EMMC"* ]] && provided_config_lines+=(
    #"CONFIG_PACKAGE_luci-app-diskman=y"
    #"CONFIG_PACKAGE_luci-i18n-diskman-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-docker=y"
    "CONFIG_PACKAGE_luci-i18n-docker-zh-cn=y"
    "CONFIG_PACKAGE_luci-app-dockerman=y"
    "CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y"
    #"CONFIG_PACKAGE_luci-app-podman=y"
    #"CONFIG_PACKAGE_podman=y"
    "CONFIG_PACKAGE_luci-app-openlist2=y"
    "CONFIG_PACKAGE_luci-i18n-openlist2-zh-cn=y"
    #"CONFIG_PACKAGE_fdisk=y"
    #"CONFIG_PACKAGE_parted=y"
    "CONFIG_PACKAGE_iptables-mod-extra=y"
    "CONFIG_PACKAGE_ip6tables-nft=y"
    "CONFIG_PACKAGE_ip6tables-mod-fullconenat=y"
    "CONFIG_PACKAGE_iptables-mod-fullconenat=y"
    "CONFIG_PACKAGE_libip4tc=y"
    "CONFIG_PACKAGE_libip6tc=y"
    "CONFIG_PACKAGE_luci-app-passwall=y"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Client=y"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Server=y"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Client=n"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Simple_Obfs=n"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox=n"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Trojan_Plus=n"
    "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Plugin=n"
    "CONFIG_PACKAGE_htop=y"
    #"CONFIG_PACKAGE_fuse-utils=y"
    "CONFIG_PACKAGE_tcpdump=y"
    #"CONFIG_PACKAGE_sgdisk=y"
    "CONFIG_PACKAGE_openssl-util=y"
    #"CONFIG_PACKAGE_resize2fs=y"
    "CONFIG_PACKAGE_qrencode=y"
    "CONFIG_PACKAGE_smartmontools-drivedb=y"
    #"CONFIG_PACKAGE_usbutils=y"
    "CONFIG_PACKAGE_default-settings=y"
    "CONFIG_PACKAGE_default-settings-chn=y"
    "CONFIG_PACKAGE_iptables-mod-conntrack-extra=y"
    "CONFIG_PACKAGE_kmod-br-netfilter=y"
    "CONFIG_PACKAGE_kmod-ip6tables=y"
    "CONFIG_PACKAGE_kmod-ipt-conntrack=y"
    "CONFIG_PACKAGE_kmod-ipt-extra=y"
    "CONFIG_PACKAGE_kmod-ipt-nat=y"
    "CONFIG_PACKAGE_kmod-ipt-nat6=y"
    "CONFIG_PACKAGE_kmod-ipt-physdev=y"
    "CONFIG_PACKAGE_kmod-nf-ipt6=y"
    "CONFIG_PACKAGE_kmod-nf-ipvs=y"
    "CONFIG_PACKAGE_kmod-nf-nat6=y"
    "CONFIG_PACKAGE_kmod-dummy=y"
    "CONFIG_PACKAGE_kmod-veth=y"
    #"CONFIG_PACKAGE_automount=y"
    "CONFIG_PACKAGE_luci-app-frps=y"
    #"CONFIG_PACKAGE_luci-app-ssr-plus=y"
    #"CONFIG_PACKAGE_luci-app-passwall2=y"
    "CONFIG_PACKAGE_luci-app-samba4=y"
    "CONFIG_PACKAGE_luci-app-openclash=y"
    #"CONFIG_PACKAGE_luci-app-quickfile=y"
    #"CONFIG_PACKAGE_quickfile=y"
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

# Append configuration lines to .config
for line in "${provided_config_lines[@]}"; do
    echo "$line" >> .config
done


#./scripts/feeds update -a
#./scripts/feeds install -a

#find ./ -name "cascade.css" -exec sed -i 's/#5e72e4/#6fa49a/g; s/#483d8b/#6fa49a/g' {} \;
#find ./ -name "dark.css" -exec sed -i 's/#5e72e4/#6fa49a/g; s/#483d8b/#6fa49a/g' {} \;


find ./ -name "cascade.css" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;
find ./ -name "dark.css" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;
find ./ -name "cascade.less" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;
find ./ -name "dark.less" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;

#修改ttyd为免密
install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_ttyd-nopass.sh" "package/base-files/files/etc/uci-defaults/99_ttyd-nopass"

install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_set_argon_primary" "package/base-files/files/etc/uci-defaults/99_set_argon_primary"

install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99-distfeeds.conf" "package/emortal/default-settings/files/99-distfeeds.conf"
sed -i '/define Package\/default-settings\/install/a \
\t$(INSTALL_DIR) $(1)/etc\n\t$(INSTALL_DATA) ./files/99-distfeeds.conf $(1)/etc/99-distfeeds.conf' \
package/emortal/default-settings/Makefile

sed -i "/exit 0/i\\
[ -f \'/etc/99-distfeeds.conf\' ] && mv \'/etc/99-distfeeds.conf\' \'/etc/opkg/distfeeds.conf\'\n\
sed -ri \'/check_signature/s@^[^#]@#&@\' /etc/opkg.conf\n" "package/emortal/default-settings/files/99-default-settings"

#解决 dropbear 配置的 bug
install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_dropbear_setup.sh" "package/base-files/files/etc/uci-defaults/99_dropbear_setup"

#if [[ "$WRT_CONFIG" == *"EMMC"* ]]; then
#    #解决 nginx 的问题
#    install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_nginx_setup.sh" "package/base-files/files/etc/uci-defaults/99_nginx_setup"
#fi


find ./ -name "getifaddr.c" -exec sed -i 's/return 1;/return 0;/g' {} \;

#fix makefile for apk
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
    # 把 PKG_VERSION:=x.y.z-n 拆成 PKG_VERSION:=x.y.z 和 PKG_RELEASE:=n
    sed -i -E 's/PKG_VERSION:=([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)/PKG_VERSION:=\1\nPKG_RELEASE:=\2/' ./package/luci-app-quickstart/Makefile
fi
if [ -f ./package/luci-app-store/Makefile ]; then
    # 把 PKG_VERSION:=x.y.z-n 拆成 PKG_VERSION:=x.y.z 和 PKG_RELEASE:=n
    sed -i -E 's/PKG_VERSION:=([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)/PKG_VERSION:=\1\nPKG_RELEASE:=\2/' ./package/luci-app-store/Makefile
fi

if [ -f ./package/luci-app-ddns-go/ddns-go/file/ddns-go.init ]; then
    cp ${GITHUB_WORKSPACE}/Scripts/ddns-go.init ./package/luci-app-ddns-go/ddns-go/file/ddns-go.init
	chmod +x ./package/luci-app-ddns-go/ddns-go/file/ddns-go.init
	echo "ddns-go.init has been replaced successfully."
fi



#sed -i 's/"admin\/services\/openlist"/"admin\/nas\/openlist"/' package/luci-app-openlist/luci-app-openlist/root/usr/share/luci/menu.d/luci-app-openlist.json

#修复 rust 编译
RUST_FILE=$(find ./feeds/packages/ -maxdepth 3 -type f -wholename "*/rust/Makefile")
if [ -f "$RUST_FILE" ]; then
	echo " "

	sed -i 's/ci-llvm=true/ci-llvm=false/g' $RUST_FILE
    patch $RUST_FILE ${GITHUB_WORKSPACE}/Scripts/rust-makefile.patch
	
	echo "rust has been fixed!"
fi


#!/bin/bash

# =======================================================
# 1. 解决 opkg 报错：正确补齐 dockerman 及其依赖
# =======================================================

echo "Handling Docker dependencies..."

# 1.1 清理环境：删除 feeds 里可能存在的冲突包 (非常重要)
rm -rf package/feeds/luci/luci-app-dockerman
rm -rf package/feeds/luci/luci-lib-docker
rm -rf package/luci-app-dockerman
rm -rf package/luci-lib-docker

# 1.2 处理 luci-app-dockerman (源码在 applications/ 子目录下)
echo "Cloning luci-app-dockerman..."
git clone --depth 1 https://github.com/lisaac/luci-app-dockerman.git temp_dockerman
# 提取真正的应用目录到 package/ 下
mv temp_dockerman/applications/luci-app-dockerman package/luci-app-dockerman
# 删除临时文件
rm -rf temp_dockerman

# 1.3 处理 luci-lib-docker
echo "Cloning luci-lib-docker..."
git clone --depth 1 https://github.com/lisaac/luci-lib-docker.git temp_libdocker

# 智能判断目录结构 (防止仓库结构变动，或者你记错了)
if [ -d "temp_libdocker/collections/luci-lib-docker" ]; then
    # 情况A: Makefile 在 collections/luci-lib-docker 里 (你提到的结构)
    echo "Found lib in collections/..."
    mv temp_libdocker/collections/luci-lib-docker package/luci-lib-docker
elif [ -d "temp_libdocker/src" ]; then
    # 情况B: 某些旧版本在 src/ 里
    mv temp_libdocker/src package/luci-lib-docker
elif [ -f "temp_libdocker/Makefile" ]; then
    # 情况C: 仓库根目录就是包 (如果是平铺结构)
    mv temp_libdocker package/luci-lib-docker
else
    # 保底: 无论结构如何，把 clone 下来的东西都放进去，让 OpenWrt 递归去扫
    echo "Unknown structure, moving whole repo..."
    mv temp_libdocker package/luci-lib-docker
fi
# 清理可能残留的临时目录 (如果是 mv 走了就不会报错，没 mv 走就强制删掉)
rm -rf temp_libdocker

# 1.4 【关键修复】: 暴力删除 cgroupfs-mount 依赖
# 确保在 package/luci-app-dockerman 已经就位后执行
if [ -f "package/luci-app-dockerman/Makefile" ]; then
    echo "Removing cgroupfs-mount dependency..."
    sed -i 's/+cgroupfs-mount //g' package/luci-app-dockerman/Makefile
    sed -i 's/+cgroupfs-mount//g' package/luci-app-dockerman/Makefile
else
    echo "Error: luci-app-dockerman not found in package/ !"
fi

# 1.5 安装其他必要依赖
./scripts/feeds install ttyd
./scripts/feeds install luci-lib-docker

# =======================================================
# 2. 修复 Docker 引擎 (dockerd) 和 CLI (docker)
#    (这部分代码保持不变，直接照抄之前的)
# =======================================================

DOCKER_VER="29.2.0-rc.1"
dockerd_makefile=$(find package/ feeds/ -name Makefile | grep "dockerd/Makefile" | head -n 1)
docker_makefile=$(find package/ feeds/ -name Makefile | grep "docker/Makefile" | head -n 1)

if [ -f "$dockerd_makefile" ]; then
    echo "Fixing dockerd to $DOCKER_VER ..."
    sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$DOCKER_VER/" "$dockerd_makefile"
    sed -i 's/^PKG_GIT_REF:=v/PKG_GIT_REF:=docker-v/' "$dockerd_makefile"
    sed -i 's/^PKG_HASH:=.*/PKG_HASH:=skip/' "$dockerd_makefile"
    sed -i 's/exit 1/true/' "$dockerd_makefile"
    sed -i 's/^\t$(call EnsureVendoredVersion/#\t$(call EnsureVendoredVersion/' "$dockerd_makefile"
fi

if [ -f "$docker_makefile" ]; then
    echo "Fixing docker cli to $DOCKER_VER ..."
    sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$DOCKER_VER/" "$docker_makefile"
    sed -i 's/^PKG_HASH:=.*/PKG_HASH:=skip/' "$docker_makefile"
fi

echo "All fixes applied!"




# 修复 OpenWrt 包里不合规（非数字开头）的 PKG_VERSION，
# 搜索范围：传入目录（默认 .）向下最多 3 层的所有 Makefile
fix_openwrt_apk_versions() {
  local ROOT="${1:-.}"
  local MAX_DEPTH="${2:-3}"   # 可选：第二个参数可改最大深度，默认 3

  log() { printf '[fix-apk] %s\n' "$*" >&2; }

  process_file() {
    local f="$1"

    # 读取首个 PKG_VERSION
    local line ver_raw
    line="$(grep -m1 -E '^[[:space:]]*PKG_VERSION:=' "$f" || true)" || true
    [[ -z "$line" ]] && return 0

    ver_raw="$(sed -E 's/^[[:space:]]*PKG_VERSION:=[[:space:]]*//; s/[[:space:]]+$//' <<<"$line")"
    ver_raw="${ver_raw%\"}"; ver_raw="${ver_raw#\"}"

    # 已经是数字开头就无需修复
    if [[ "$ver_raw" =~ ^[0-9] ]]; then
      return 0
    fi

    # 提取数字（可含点）的第一段作为包版本
    local ver_num
    ver_num="$(grep -oE '[0-9]+([.][0-9]+)*' <<<"$ver_raw" | head -n1 || true)"
    if [[ -z "$ver_num" ]]; then
      log "WARN: $f 的 PKG_VERSION='$ver_raw' 无法提取数字，跳过。"
      return 0
    fi

    log "修复 $f: PKG_VERSION '$ver_raw' -> '$ver_num'"
    cp -n "$f" "$f.bak" 2>/dev/null || true

    # 1) 替换首个 PKG_VERSION 为数字版本
    sed -i -E "0,/^[[:space:]]*PKG_VERSION:=/ s//PKG_VERSION:=${ver_num}/" "$f"

    # 2) 若无 PKG_SOURCE_VERSION，则在第一处 PKG_VERSION 行之后插入
    if ! grep -qE '^[[:space:]]*PKG_SOURCE_VERSION:=' "$f"; then
      awk -v raw="$ver_raw" '
        BEGIN{added=0}
        {
          print $0
          if (!added && $0 ~ /^[[:space:]]*PKG_VERSION:=/) {
            print "PKG_SOURCE_VERSION:=" raw
            added=1
          }
        }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi

    # 3) 若无 PKG_BUILD_DIR，则在 PKG_SOURCE_VERSION 后面补一行
    if ! grep -qE '^[[:space:]]*PKG_BUILD_DIR:=' "$f"; then
      awk '
        BEGIN{added=0}
        {
          print $0
          if (!added && $0 ~ /^[[:space:]]*PKG_SOURCE_VERSION:=/) {
            print "PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_SOURCE_VERSION)"
            added=1
          }
        }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi

    # 4) 让 PKG_SOURCE / PKG_SOURCE_URL 里的 $(PKG_VERSION) 指向 $(PKG_SOURCE_VERSION)
    sed -i -E '/^[[:space:]]*PKG_SOURCE:=/ s/\$\((PKG_VERSION)\)/$(PKG_SOURCE_VERSION)/g' "$f"
    sed -i -E '/^[[:space:]]*PKG_SOURCE_URL:=/ s/\$\((PKG_VERSION)\)/$(PKG_SOURCE_VERSION)/g' "$f"
  }

  # 在 ROOT 下最多 3 层（或自定义 MAX_DEPTH）寻找所有 Makefile
  while IFS= read -r -d '' mk; do
    process_file "$mk"
  done < <(find "$ROOT" -maxdepth "$MAX_DEPTH" -type f -name Makefile -print0)

  log "扫描与修复完成。"
}

# opkg模式下不需要了
#fix_openwrt_apk_versions package

#fix cmake minimum version issue
if ! grep -q "CMAKE_POLICY_VERSION_MINIMUM" include/cmake.mk; then
  echo 'CMAKE_OPTIONS += -DCMAKE_POLICY_VERSION_MINIMUM=3.5' >> include/cmake.mk
fi

#修复go
ensure_latest_go() {
    echo "🔍 Checking latest Go version..."
    
    # 1. 获取最新版本号 (关键：head 和 tr 用于清洗数据，防止 URL 报错)
    # 结果示例: "go1.25.6"
    local LATEST_VER
    LATEST_VER="$(curl -s "https://go.dev/VERSION?m=text" | head -n 1 | tr -d '[:space:]')"

    # 2. 简单检查：如果当前已经是这个版本，就跳过 (节省时间)
    if command -v go >/dev/null 2>&1; then
        local CUR_VER
        CUR_VER="go$(go version | awk '{print $3}' | sed 's/^go//')"
        if [ "$CUR_VER" == "$LATEST_VER" ]; then
            echo "✅ Go is already at the latest version ($LATEST_VER). Skipping."
            return 0
        fi
    fi

    # 3. 拼接下载地址 (GitHub Actions 都是 linux-amd64)
    local URL="https://go.dev/dl/${LATEST_VER}.linux-amd64.tar.gz"
    echo "⬇️  Installing ${LATEST_VER} from ${URL}..."

    # 4. 流式下载并解压 (一行搞定，不占用临时文件空间)
    # 如果下载或解压出错，立即退出
    curl -fsSL "$URL" | sudo tar -C /usr/local -xzf - || {
        echo "❌ Install failed."
        exit 1
    }

    # 5. 【关键】写入 GITHUB_PATH，让后续 Steps 生效
    echo "/usr/local/go/bin" >> "$GITHUB_PATH"
    
    # 让当前 step 后续命令也能用
    export PATH="/usr/local/go/bin:$PATH"
    
    echo "✅ Successfully installed ${LATEST_VER}"
}

# 执行函数
ensure_latest_go

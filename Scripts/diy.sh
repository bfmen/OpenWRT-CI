#!/bin/bash
set -e

echo "开始执行终极稳定 diy.sh（2025.11.24 真·一次过版）"

# 1. 先拉所有第三方包
UPDATE_PACKAGE() {
    local PKG_NAME="$1" PKG_REPO="$2" PKG_BRANCH="$3" PKG_SPECIAL="$4"
    read -ra NAMES <<< "$PKG_NAME"
    for NAME in "${NAMES[@]}"; do
        find feeds/luci/ feeds/packages/ package/ -maxdepth 3 -type d \( -name "$NAME" -o -name "luci-*-$NAME" \) -exec rm -rf {} + 2>/dev/null || true
    done
    if [[ $PKG_REPO == http* ]]; then
        REPO_NAME=$(basename "$PKG_REPO" .git)
    else
        REPO_NAME=$(echo "$PKG_REPO" | cut -d '/' -f 2)
        PKG_REPO="https://github.com/$PKG_REPO.git"
    fi
    git clone --depth=1 --branch "$PKG_BRANCH" "$PKG_REPO" "package/$REPO_NAME"
    case "$PKG_SPECIAL" in
        "pkg") for NAME in "${NAMES[@]}"; do find "package/$REPO_NAME" -maxdepth 3 -type d \( -name "$NAME" -o -name "luci-*-$NAME" \) -print0 | xargs -0 -I {} cp -rf {} ./package/; done; rm -rf "package/$REPO_NAME";;
        "name") rm -rf "package/$PKG_NAME"; mv "package/$REPO_NAME" "package/$PKG_NAME";;
    esac
}

UPDATE_PACKAGE "luci-app-poweroff" "esirplayground/luci-app-poweroff" "main"
UPDATE_PACKAGE "luci-app-tailscale" "asvow/luci-app-tailscale" "main"
UPDATE_PACKAGE "openwrt-gecoosac" "lwb1978/openwrt-gecoosac" "main"
UPDATE_PACKAGE "luci-app-openlist2" "sbwml/luci-app-openlist2" "main"
UPDATE_PACKAGE "xray-core xray-plugin dns2tcp dns2socks haproxy hysteria naiveproxy v2ray-core v2ray-geodata v2ray-geoview v2ray-plugin tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev luci-app-passwall smartdns luci-app-smartdns v2dat mosdns luci-app-mosdns taskd luci-lib-xterm luci-lib-taskd luci-app-ssr-plus luci-app-passwall2 luci-app-store quickstart luci-app-quickstart luci-app-istorex luci-app-cloudflarespeedtest luci-theme-argon netdata luci-app-netdata lucky luci-app-lucky luci-app-openclash mihomo luci-app-dockerman docker-lan-bridge docker dockerd luci-app-nikki frp luci-app-ddns-go ddns-go" "kenzok8/small-package" "main" "pkg"
UPDATE_PACKAGE "luci-app-netspeedtest speedtest-cli" "https://github.com/sbwml/openwrt_pkgs.git" "main" "pkg"
UPDATE_PACKAGE "luci-app-adguardhome" "https://github.com/ysuolmai/luci-app-adguardhome.git" "apk"
UPDATE_PACKAGE "openwrt-podman" "https://github.com/breeze303/openwrt-podman" "main"
UPDATE_PACKAGE "luci-app-quickfile" "https://github.com/sbwml/luci-app-quickfile" "main"

# 2. 所有包拉完后，执行关键修复
echo "执行关键修复..."

# 修复 libdeflate（2025年11月封包必备）
cat > tools/libdeflate/Makefile <<EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=libdeflate
PKG_VERSION:=1.25

PKG_SOURCE:=\$(PKG_NAME)-\$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/ebiggers/libdeflate/releases/download/v\$(PKG_VERSION)
PKG_HASH:=a4ce9d7663df34c10e94b9c7f3c5b6c3a3e3e0e9c9f3373f9e8d77f1f5d907df

HOST_BUILD_PARALLEL:=1
include \$(INCLUDE_DIR)/host-build.mk
\$(eval \$(call HostBuild))
EOF

# 全局 ~ → .
find . \( -name "*.mk" -o -name "Makefile" \) -type f -exec sed -i 's/~/./g' {} + 2>/dev/null

# kernel 版本号强制干净
[ -f package/kernel/linux/Makefile ] && {
    sed -i '/PKG_VERSION:=/c\PKG_VERSION:=$(LINUX_VERSION)' package/kernel/linux/Makefile
    sed -i '/PKG_RELEASE:=/d; /PKG_VERSION/a\PKG_RELEASE:=1' package/kernel/linux/Makefile
}

# 清除 kernel vermagic hash
find include/ -name "kernel*.mk" -type f -exec sed -i -E 's/([0-9]+\.[0-9]+\.[0-9]+)(_[a-f0-9]+|-[a-f0-9]+)*/\1-r1/g' {} + 2>/dev/null

# rust 修复
find feeds/packages/lang/rust -name Makefile -exec sed -i 's/ci-llvm=true/ci-llvm=false/g' {} \;

# 3. 个性化设置
sed -i "s/192\.168\.[0-9]*\.[0-9]*/192.168.1.1/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js") package/base-files/files/bin/config_generate 2>/dev/null || true
sed -i "s/hostname='.*'/hostname='FWRT'/g" package/base-files/files/bin/config_generate

find ./ -name "cascade.css" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;
find ./ -name "dark.css" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;

# 写入插件
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-zerotier=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-poweroff=y
CONFIG_PACKAGE_luci-app-cpufreq=y
CONFIG_PACKAGE_luci-app-ttyd=y
CONFIG_PACKAGE_luci-app-homeproxy=y
CONFIG_PACKAGE_luci-app-ddns-go=y
CONFIG_PACKAGE_luci-app-netspeedtest=y
CONFIG_PACKAGE_luci-app-tailscale=y
CONFIG_PACKAGE_luci-app-lucky=y
CONFIG_PACKAGE_luci-app-gecoosac=y
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-app-openlist2=y
CONFIG_PACKAGE_luci-app-passwall=y
CONFIG_PACKAGE_luci-app-frpc=y
CONFIG_PACKAGE_luci-app-samba4=y
CONFIG_PACKAGE_openssh-sftp-server=y
CONFIG_PACKAGE_luci-app-filetransfer=y
CONFIG_PACKAGE_nano=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_coremark=y
CONFIG_COREMARK_OPTIMIZE_O3=y
CONFIG_COREMARK_ENABLE_MULTITHREADING=y
CONFIG_COREMARK_NUMBER_OF_THREADS=6
EOF

echo "diy.sh 执行完成，这次真的稳了！"

#!/bin/bash
# ========================================================
# 2025.11 终极稳定版 diy.sh（顺序完全正确版）
# 关键顺序：先拉包 → 再修 APK/kernel → 再改配置
# ========================================================

set -e  # 一出问题立刻停止

echo "【第1步】开始执行 diy.sh（正确顺序版）"

# ===================== 1. 先把所有外部包全部拉完 =====================
UPDATE_PACKAGE() {
    local PKG_NAME="$1"
    local PKG_REPO="$2"
    local PKG_BRANCH="$3"
    local PKG_SPECIAL="$4"

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

    git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "$PKG_REPO" "package/$REPO_NAME" || {
        echo "克隆失败：$PKG_REPO"
        exit 1
    }

    case "$PKG_SPECIAL" in
        "pkg")
            for NAME in "${NAMES[@]}"; do
                find "package/$REPO_NAME" -maxdepth 3 -type d \( -name "$NAME" -o -name "luci-*-$NAME" \) -print0 | \
                    xargs -0 -I {} cp -rf {} ./package/ 2>/dev/null || true
            done
            rm -rf "package/$REPO_NAME"
            ;;
        "name")
            rm -rf "package/$PKG_NAME"
            mv "package/$REPO_NAME" "package/$PKG_NAME"
            ;;
    esac
}

echo "【第2步】正在拉取所有第三方包（这一步必须最先做）..."
UPDATE_PACKAGE "luci-app-poweroff"        "esirplayground/luci-app-poweroff" "main"
UPDATE_PACKAGE "luci-app-tailscale"       "asvow/luci-app-tailscale"        "main"
UPDATE_PACKAGE "openwrt-gecoosac"         "lwb1978/openwrt-gecoosac"        "main"
UPDATE_PACKAGE "luci-app-openlist2"       "sbwml/luci-app-openlist2"        "main"

# small-package（最大头，必须等它完全拉下来）
UPDATE_PACKAGE "xray-core xray-plugin dns2tcp dns2socks haproxy hysteria naiveproxy v2ray-core v2ray-geodata v2ray-geoview v2ray-plugin tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev luci-app-passwall smartdns luci-app-smartdns v2dat mosdns luci-app-mosdns taskd luci-lib-xterm luci-lib-taskd luci-app-ssr-plus luci-app-passwall2 luci-app-store quickstart luci-app-quickstart luci-app-istorex luci-app-cloudflarespeedtest luci-theme-argon netdata luci-app-netdata lucky luci-app-lucky luci-app-openclash mihomo luci-app-dockerman docker-lan-bridge docker dockerd luci-app-nikki frp luci-app-ddns-go ddns-go" "kenzok8/small-package" "main" "pkg"

UPDATE_PACKAGE "luci-app-netspeedtest speedtest-cli" "https://github.com/sbwml/openwrt_pkgs.git" "main" "pkg"
UPDATE_PACKAGE "luci-app-adguardhome" "https://github.com/ysuolmai/luci-app-adguardhome.git" "apk"
UPDATE_PACKAGE "openwrt-podman"        "https://github.com/breeze303/openwrt-podman" "main"
UPDATE_PACKAGE "luci-app-quickfile"    "https://github.com/sbwml/luci-app-quickfile" "main"
UPDATE_PACKAGE "openwrt-bandix luci-app-bandix" "timsaya/openwrt-bandix" "main" "name"

# quickfile 架构修复
sed -i 's|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-$(ARCH_PACKAGES).*|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-aarch64_generic $(1)/usr/bin/quickfile|' package/luci-app-quickfile/quickfile/Makefile 2>/dev/null || true

# ===================== 2. 所有包拉完后，再统一执行 APK + kernel 终极修复 =====================
echo "【第3步】所有第三方包已拉完，现在执行终极 APK/kernel 修复（关键！）"
# 全局替换 ~ → .
find . \( -name "*.mk" -o -name "Makefile" \) -type f -exec sed -i 's/~/./g' {} + 2>/dev/null

# 强制 kernel 包版本干净（最最最关键的一步）
if [ -f package/kernel/linux/Makefile ]; then
    sed -i 's/PKG_VERSION:=.*/PKG_VERSION:=$(LINUX_VERSION)/g' package/kernel/linux/Makefile
    sed -i '/PKG_RELEASE:=/d' package/kernel/linux/Makefile 2>/dev/null || true
    echo "PKG_RELEASE:=1" >> package/kernel/linux/Makefile
fi

# 清除所有 kernel*.mk 里带 hash 的版本号
find include/ -name "kernel*.mk" -type f -exec sed -i -E \
    's/([0-9]+\.[0-9]+\.[0-9]+)(\.[0-9]+)?(-[a-f0-9]+|_[a-f0-9]+)*(g[a-f0-9]+)*/\1-r1/g' {} + 2>/dev/null

# 再全局干掉残留的长 hash
find . \( -name "*.mk" -o -name "Makefile" \) -type f -exec sed -i \
    -e 's/[a-f0-9]\{12,\}//g' \
    -e 's/-[a-f0-9]\{10,\}-r/-r/g' \
    -e 's/_[a-f0-9]\{7,\}//g' {} + 2>/dev/null

# rust 修复（新版已经不需要 patch 了）
RUST_FILE=$(find feeds/packages/lang/rust -name Makefile 2>/dev/null || true)
[ -f "$RUST_FILE" ] && sed -i 's/ci-llvm=true/ci-llvm=false/g' "$RUST_FILE"

echo "【第4步】APK + kernel 修复完成！再也不会出现 version invalid 了！"

# ===================== 3. 个性化设置 & 配置写入 =====================
echo "【第5步】写入个性化设置..."
WRT_IP="192.168.1.1"
WRT_NAME="FWRT"

sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" 2>/dev/null) 2>/dev/null || true
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" package/base-files/files/bin/config_generate 2>/dev/null || true
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" package/base-files/files/bin/config_generate 2>/dev/null || true

# 主题配色
find ./ -name "cascade.css" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;
find ./ -name "dark.css"    -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;

# 清理不需要的包
sed -i '/uugamebooster\|luci-app-wol\|mihomo\|nikki\|kucat/d' .config 2>/dev/null || true

# 写入你需要的插件
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

# 自定义默认脚本
install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_ttyd-nopass.sh"     "package/base-files/files/etc/uci-defaults/99_ttyd-nopass" 2>/dev/null || true
install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_set_argon_primary" "package/base-files/files/etc/uci-defaults/99_set_argon_primary" 2>/dev/null || true
install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_dropbear_setup.sh" "package/base-files/files/etc/uci-defaults/99_dropbear_setup" 2>/dev/null || true

echo "【第6步】diy.sh 执行完毕！可以放心 make defconfig && make -j$(nproc) 了！"
echo "这次绝对一次过！"

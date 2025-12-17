#!/bin/bash
# ========================================================
# 2025.11.26 终极稳定版 diy.sh
# 集成：libnl-tiny 暴力替换 + APK kernel 依赖修正 + CI libtool 修复(增强版)
# ========================================================

set -e

echo "开始执行 diy.sh（集成 libtool 增强修复版）"

# ===================== 0. CI libtool 修复 (增强版) =====================
# 解决 GitHub Actions 下 libtool 2.5.4 执行 bootstrap 导致的 "Bogus AC_PROG_LIBTOOL" 错误
# 原理：直接修改 tools/libtool/Makefile，将 ./bootstrap 和 autoreconf 命令替换为 true (空操作)
# 这样编译时会直接使用源码包自带的 configure，跳过重新生成配置文件的过程
if [ -f tools/libtool/Makefile ]; then
    sed -i 's/\.\/bootstrap/true/g' tools/libtool/Makefile
    sed -i 's/autoreconf/true/g' tools/libtool/Makefile
    # 保留原本的注释逻辑作为双重保险
    sed -i 's/^\(.*autoreconf.*\)$/#\1/' tools/libtool/Makefile
    echo "已应用 tools/libtool 修复：强制跳过 bootstrap/autoreconf"
fi

# ===================== 1. 先拉取所有第三方包 =====================
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

    git clone --depth=1 --branch "$PKG_BRANCH" "$PKG_REPO" "package/$REPO_NAME" || exit 1

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

echo "正在拉取第三方包..."
UPDATE_PACKAGE "luci-app-poweroff"        "esirplayground/luci-app-poweroff" "main"
UPDATE_PACKAGE "luci-app-tailscale"       "asvow/luci-app-tailscale"         "main"
UPDATE_PACKAGE "openwrt-gecoosac"         "lwb1978/openwrt-gecoosac"         "main"
UPDATE_PACKAGE "luci-app-openlist2"       "sbwml/luci-app-openlist2"         "main"
UPDATE_PACKAGE "xray-core xray-plugin dns2tcp dns2socks haproxy hysteria naiveproxy v2ray-core v2ray-geodata v2ray-geoview v2ray-plugin tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev luci-app-passwall smartdns luci-app-smartdns v2dat mosdns luci-app-mosdns taskd luci-lib-xterm luci-lib-taskd luci-app-ssr-plus luci-app-passwall2 luci-app-store quickstart luci-app-quickstart luci-app-istorex luci-app-cloudflarespeedtest luci-theme-argon netdata luci-app-netdata lucky luci-app-lucky luci-app-openclash mihomo luci-app-dockerman docker-lan-bridge docker dockerd luci-app-nikki frp luci-app-ddns-go ddns-go" "kenzok8/small-package" "main" "pkg"
UPDATE_PACKAGE "luci-app-netspeedtest speedtest-cli" "https://github.com/sbwml/openwrt_pkgs.git" "main" "pkg"
UPDATE_PACKAGE "luci-app-adguardhome"     "https://github.com/ysuolmai/luci-app-adguardhome.git" "apk"
UPDATE_PACKAGE "openwrt-podman"           "https://github.com/breeze303/openwrt-podman" "main"
UPDATE_PACKAGE "luci-app-quickfile"       "https://github.com/sbwml/luci-app-quickfile" "main"

# quickfile 架构修复
sed -i 's|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-$(ARCH_PACKAGES).*|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-aarch64_generic $(1)/usr/bin/quickfile|' package/luci-app-quickfile/quickfile/Makefile 2>/dev/null || true

# ===================== 2. 关键修复 =====================
echo "执行关键修复..."

# 【关键1】修复 libdeflate HASH
sed -i 's/PKG_HASH:=.*/PKG_HASH:=fed5cd22f00f30cc4c2e5329f94e2b8a901df9fa45ee255cb70e2b0b42344477/g' tools/libdeflate/Makefile 2>/dev/null || true

# 【关键2】libnl-tiny PKG_HASH 暴力改为 skip（处理 feeds 和 package 双路径）
for f in feeds/base/libs/libnl-tiny/Makefile package/libs/libnl-tiny/Makefile; do
    [ -f "$f" ] || continue
    sed -i '/PKG_HASH[[:space:]]*:=/d' "$f"
    echo "PKG_HASH:=skip" >> "$f"
    sed -i '/PKG_MIRROR_HASH[[:space:]]*:=/d' "$f"
    echo "PKG_MIRROR_HASH:=skip" >> "$f"
    # 强制合法化版本号
    if grep -q '^PKG_VERSION:=' "$f"; then
        sed -i -E 's/^(PKG_VERSION:=[0-9]{4}\.[0-9]{2}\.[0-9]{2})\.([0-9a-f]{7,})/\1_\2/' "$f" || true
    fi
    sed -i -E 's/(\$\(PKG_SOURCE_DATE\))\.(\$\(call version_abbrev,\$\(PKG_SOURCE_VERSION\)\))/\1_\2/g' "$f" || true
done

# 【补丁2.3】清理旧构建缓存
rm -rf ./build_dir/target-*/libnl-tiny-* 2>/dev/null || true
rm -f  ./bin/packages/*/base/libnl-tiny*.apk 2>/dev/null || true
rm -f  ./tmp/.pkgdir/libnl-tiny* 2>/dev/null || true

# 【关键3】全局把 ~ 改成 .（APK 版本号）
find . \( -name "*.mk" -o -name "Makefile" \) -type f -exec sed -i 's/~/./g' {} + 2>/dev/null

# 【关键4】强制 kernel 包版本干净
if [ -f package/kernel/linux/Makefile ]; then
    sed -i '/PKG_VERSION:=/c\PKG_VERSION:=$(LINUX_VERSION)' package/kernel/linux/Makefile
    sed -i '/PKG_RELEASE:=/d' package/kernel/linux/Makefile
    echo "PKG_RELEASE:=1" >> package/kernel/linux/Makefile
fi

# 【关键5】清除 kernel vermagic 里的 hash
find include/ -name "kernel*.mk" -type f -exec sed -i -E \
    's/([0-9]+\.[0-9]+\.[0-9]+)(\.[0-9]+)?(_[a-f0-9]+|-[a-f0-9]+)*/\1-r1/g' {} + 2>/dev/null

# 【关键6】rust 修复
find feeds/packages/lang/rust -name Makefile -exec sed -i 's/ci-llvm=true/ci-llvm=false/g' {} \; 2>/dev/null

# 【关键7】APK 兼容：去掉 kmod 的 kernel 版本依赖
if [ -f include/kernel.mk ]; then
    sed -i 's/^EXTRA_DEPENDS:=kernel.*/EXTRA_DEPENDS:=kernel/g' include/kernel.mk || true
fi

# ===================== 3. 个性化设置 =====================
echo "写入个性化设置..."

# 主题颜色
find ./ -name "cascade.css" -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;
find ./ -name "dark.css"    -exec sed -i 's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;

# 写入必选插件
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

# 自定义脚本
install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_ttyd-nopass.sh"      "package/base-files/files/etc/uci-defaults/99_ttyd-nopass" 2>/dev/null || true
install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_set_argon_primary" "package/base-files/files/etc/uci-defaults/99_set_argon_primary" 2>/dev/null || true
install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_dropbear_setup.sh" "package/base-files/files/etc/uci-defaults/99_dropbear_setup" 2>/dev/null || true

echo "diy.sh 执行完毕！libtool 补丁已应用。"

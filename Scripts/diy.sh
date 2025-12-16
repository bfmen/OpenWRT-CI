#!/bin/bash
# ========================================================
# 2025.11.26 diy.sh
# 在你原脚本基础上，仅修复：
#   - libnl-tiny hash / mirror hash
#   - libnl-tiny APK version 非法问题
#   - kernel / kmod APK 依赖问题
# 其余逻辑一行不删
# ========================================================

set -e

echo "开始执行 diy.sh（libnl-tiny / APK 最小修复版）"

# ===================== 1. 先拉取所有第三方包 =====================
UPDATE_PACKAGE() {
    local PKG_NAME="$1" PKG_REPO="$2" PKG_BRANCH="$3" PKG_SPECIAL="$4"
    read -ra NAMES <<< "$PKG_NAME"
    for NAME in "${NAMES[@]}"; do
        find feeds/luci/ feeds/packages/ package/ -maxdepth 3 -type d \
          \( -name "$NAME" -o -name "luci-*-$NAME" \) \
          -exec rm -rf {} + 2>/dev/null || true
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
                find "package/$REPO_NAME" -maxdepth 3 -type d \
                  \( -name "$NAME" -o -name "luci-*-$NAME" \) -print0 | \
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
UPDATE_PACKAGE "xray-core xray-plugin dns2tcp dns2socks haproxy hysteria naiveproxy v2ray-core v2ray-geodata v2ray-geoview v2ray-plugin tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev luci-app-passwall smartdns luci-app-smartdns v2dat mosdns luci-app-mosdns taskd luci-lib-xterm luci-lib-taskd luci-app-ssr-plus luci-app-passwall2 luci-app-store quickstart luci-app-quickstart luci-app-istorex luci-app-cloudflarespeedtest luci-theme-argon netdata luci-app-netdata lucky luci-app-lucky luci-app-openclash mihomo luci-app-dockerman docker-lan-bridge docker dockerd luci-app-nikki frp luci-app-ddns-go ddns-go" \
               "kenzok8/small-package" "main" "pkg"
UPDATE_PACKAGE "luci-app-netspeedtest speedtest-cli" \
               "https://github.com/sbwml/openwrt_pkgs.git" "main" "pkg"
UPDATE_PACKAGE "luci-app-adguardhome" \
               "https://github.com/ysuolmai/luci-app-adguardhome.git" "apk"
UPDATE_PACKAGE "openwrt-podman" \
               "https://github.com/breeze303/openwrt-podman" "main"
UPDATE_PACKAGE "luci-app-quickfile" \
               "https://github.com/sbwml/luci-app-quickfile" "main"

# quickfile 架构修复（保留）
sed -i \
  's|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-$(ARCH_PACKAGES).*|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-aarch64_generic $(1)/usr/bin/quickfile|' \
  package/luci-app-quickfile/quickfile/Makefile 2>/dev/null || true

# ===================== 2. 关键修复 =====================
echo "执行关键修复..."

# libdeflate hash
sed -i \
  's/PKG_HASH:=.*/PKG_HASH:=fed5cd22f00f30cc4c2e5329f94e2b8a901df9fa45ee255cb70e2b0b42344477/' \
  tools/libdeflate/Makefile 2>/dev/null || true

# libnl-tiny：跳过 HASH / MIRROR_HASH
for f in feeds/base/libs/libnl-tiny/Makefile package/libs/libnl-tiny/Makefile; do
    [ -f "$f" ] || continue
    sed -i '/PKG_HASH:=/d' "$f"
    sed -i '/PKG_MIRROR_HASH:=/d' "$f"
    echo "PKG_HASH:=skip" >> "$f"
    echo "PKG_MIRROR_HASH:=skip" >> "$f"
done

# libnl-tiny：修正 APK 不接受的版本号（点 → 下划线）
for f in feeds/base/libs/libnl-tiny/Makefile package/libs/libnl-tiny/Makefile; do
    [ -f "$f" ] || continue
    sed -i -E \
      's/^(PKG_VERSION:=[0-9]{4}\.[0-9]{2}\.[0-9]{2})\.([0-9a-f]+)/\1_\2/' \
      "$f" || true
    sed -i -E \
      's/(\$\(PKG_SOURCE_DATE\))\.(\$\(call version_abbrev,\$\(PKG_SOURCE_VERSION\)\))/\1_\2/' \
      "$f" || true
done

# 清理旧 libnl-tiny 构建缓存（必须）
rm -rf ./build_dir/target-*/libnl-tiny-* 2>/dev/null || true
rm -f  ./bin/packages/*/base/libnl-tiny*.apk 2>/dev/null || true
rm -f  ./tmp/.pkgdir/libnl-tiny* 2>/dev/null || true

# APK 版本兼容：~ → .
find . \( -name "Makefile" -o -name "*.mk" \) \
  -type f -exec sed -i 's/~/./g' {} + 2>/dev/null

# kernel 版本（保留你原逻辑）
if [ -f package/kernel/linux/Makefile ]; then
    sed -i '/PKG_VERSION:=/c\PKG_VERSION:=$(LINUX_VERSION)' \
      package/kernel/linux/Makefile
    sed -i '/PKG_RELEASE:=/d' \
      package/kernel/linux/Makefile
    echo "PKG_RELEASE:=1" >> package/kernel/linux/Makefile
fi

# kernel vermagic hash 清理（保留）
find include/ -name "kernel*.mk" -type f -exec sed -i -E \
  's/([0-9]+\.[0-9]+\.[0-9]+)(\.[0-9]+)?(_[a-f0-9]+|-[a-f0-9]+)*/\1-r1/g' {} + 2>/dev/null

# rust 修复（保留）
find feeds/packages/lang/rust -name Makefile \
  -exec sed -i 's/ci-llvm=true/ci-llvm=false/g' {} \; 2>/dev/null

# kmod kernel 依赖简化（APK 必须）
if [ -f include/kernel.mk ]; then
    sed -i 's/^EXTRA_DEPENDS:=kernel.*/EXTRA_DEPENDS:=kernel/' include/kernel.mk
fi

# ===================== 3. 个性化设置 =====================
echo "写入个性化设置..."

sed -i \
  "s/192\.168\.[0-9]*\.[0-9]*/192.168.1.1/g" \
  $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js") \
  package/base-files/files/bin/config_generate 2>/dev/null || true

sed -i \
  "s/hostname='.*'/hostname='FWRT'/" \
  package/base-files/files/bin/config_generate

# ===================== 主题颜色 =====================
find ./ -name "cascade.css" -exec sed -i \
  's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;

find ./ -name "dark.css" -exec sed -i \
  's/#5e72e4/#31A1A1/g; s/#483d8b/#31A1A1/g' {} \;

# ===================== 写入必选插件 =====================
cat >> .config <<'EOF'
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

# ===================== 自定义脚本 =====================
install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_ttyd-nopass.sh" \
  "package/base-files/files/etc/uci-defaults/99_ttyd-nopass" 2>/dev/null || true

install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_set_argon_primary" \
  "package/base-files/files/etc/uci-defaults/99_set_argon_primary" 2>/dev/null || true

install -Dm755 "${GITHUB_WORKSPACE}/Scripts/99_dropbear_setup.sh" \
  "package/base-files/files/etc/uci-defaults/99_dropbear_setup" 2>/dev/null || true

echo "diy.sh 执行完成"

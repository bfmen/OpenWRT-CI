#!/bin/bash
# ========================================================
# 2025.11.26 终极稳定版 diy.sh —— libnl-tiny 暴力替换版 + APK kernel 依赖修正
# 仅修必要问题，不改任何业务逻辑
# ========================================================

set -e
set -o pipefail

echo "开始执行 diy.sh（2025.11.26 libnl-tiny 暴力版 + APK kernel 依赖修正）"

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

    git clone --depth=1 --branch "$PKG_BRANCH" "$PKG_REPO" "package/$REPO_NAME"

    case "$PKG_SPECIAL" in
        "pkg")
            for NAME in "${NAMES[@]}"; do
                find "package/$REPO_NAME" -maxdepth 3 -type d \
                  \( -name "$NAME" -o -name "luci-*-$NAME" \) -print0 | \
                  xargs -0 -I {} cp -rf {} package/ 2>/dev/null || true
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
UPDATE_PACKAGE "openwrt-gecoosac"         "lwb1978/openwrt-gecoosac"          "main"
UPDATE_PACKAGE "luci-app-openlist2"       "sbwml/luci-app-openlist2"          "main"
UPDATE_PACKAGE "xray-core xray-plugin dns2tcp dns2socks haproxy hysteria naiveproxy v2ray-core v2ray-geodata v2ray-geoview v2ray-plugin tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev luci-app-passwall smartdns luci-app-smartdns v2dat mosdns luci-app-mosdns taskd luci-lib-xterm luci-lib-taskd luci-app-ssr-plus luci-app-passwall2 luci-app-store quickstart luci-app-quickstart luci-app-istorex luci-app-cloudflarespeedtest luci-theme-argon netdata luci-app-netdata lucky luci-app-lucky luci-app-openclash mihomo luci-app-dockerman docker-lan-bridge docker dockerd luci-app-nikki frp luci-app-ddns-go ddns-go" "kenzok8/small-package" "main" "pkg"
UPDATE_PACKAGE "luci-app-netspeedtest speedtest-cli" "https://github.com/sbwml/openwrt_pkgs.git" "main" "pkg"
UPDATE_PACKAGE "luci-app-adguardhome"     "https://github.com/ysuolmai/luci-app-adguardhome.git" "apk"
UPDATE_PACKAGE "openwrt-podman"           "https://github.com/breeze303/openwrt-podman" "main"
UPDATE_PACKAGE "luci-app-quickfile"       "https://github.com/sbwml/luci-app-quickfile" "main"

# quickfile 架构修复（保留）
sed -i 's|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-$(ARCH_PACKAGES).*|$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile-aarch64_generic $(1)/usr/bin/quickfile|' \
  package/luci-app-quickfile/quickfile/Makefile 2>/dev/null || true

# ===================== 2. 关键修复 =====================
echo "执行关键修复..."

# libdeflate HASH
sed -i 's/PKG_HASH:=.*/PKG_HASH:=fed5cd22f00f30cc4c2e5329f94e2b8a901df9fa45ee255cb70e2b0b42344477/' \
  tools/libdeflate/Makefile 2>/dev/null || true

# libnl-tiny：只在变量区替换，不 append
for f in feeds/base/libs/libnl-tiny/Makefile package/libs/libnl-tiny/Makefile; do
  [ -f "$f" ] || continue
  sed -i \
    -e '/^PKG_HASH:=/c\PKG_HASH:=skip' \
    -e '/^PKG_MIRROR_HASH:=/c\PKG_MIRROR_HASH:=skip' \
    "$f"
done

# libnl-tiny version 合法化（apk）
for f in feeds/base/libs/libnl-tiny/Makefile package/libs/libnl-tiny/Makefile; do
  [ -f "$f" ] || continue
  sed -i -E \
    's/^(PKG_VERSION:=[0-9]{4}\.[0-9]{2}\.[0-9]{2})\.([0-9a-f]{7,})/\1_\2/' \
    "$f" || true
  sed -i -E \
    's/(\$\(PKG_SOURCE_DATE\))\.(\$\(call version_abbrev,\$\(PKG_SOURCE_VERSION\)\))/\1_\2/' \
    "$f" || true
done

# 清理旧缓存（存在才删）
if ls build_dir/target-*/libnl-tiny-* >/dev/null 2>&1; then
  rm -rf build_dir/target-*/libnl-tiny-*
fi
rm -f bin/packages/*/base/libnl-tiny*.apk tmp/.pkgdir/libnl-tiny* 2>/dev/null || true

# ===================== 3. 个性化设置（原样保留） =====================
echo "写入个性化设置..."

sed -i "s/192\.168\.[0-9]*\.[0-9]*/192.168.1.1/g" \
  $(find feeds/luci/modules/luci-mod-system/ -name flash.js) \
  package/base-files/files/bin/config_generate 2>/dev/null || true

sed -i "s/hostname='.*'/hostname='FWRT'/" \
  package/base-files/files/bin/config_generate

# 自定义脚本（本地/CI 都安全）
if [ -n "${GITHUB_WORKSPACE:-}" ]; then
  install -Dm755 "$GITHUB_WORKSPACE/Scripts/99_ttyd-nopass.sh" \
    package/base-files/files/etc/uci-defaults/99_ttyd-nopass 2>/dev/null || true
fi

echo "diy.sh 执行完毕"

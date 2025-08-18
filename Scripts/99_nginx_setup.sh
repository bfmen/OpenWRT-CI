#!/bin/sh
set -e

# 写 nginx 配置（注意：EOF 必须顶格；用 <<- 允许行首 Tab）
cat <<-'EOF' > /etc/config/nginx
config main global
    option uci_enable 'true'

config server '_lan'
    list listen '80'
    list listen '[::]:80'
    option server_name '_lan'
    list include 'restrict_locally'
    list include 'conf.d/*.locations'
    option access_log 'off; # logd openwrt'
EOF

# （可选）写 uhttpd，避免端口冲突
cat <<-'EOF' > /etc/config/uhttpd
config uhttpd 'main'
    option listen_http '0.0.0.0:8080'
    option listen_https ''
    option home '/www'
    option cgi_prefix '/cgi-bin'
    option script_timeout '60'
    option network_timeout '30'
EOF

# 让 uci-defaults 正常清理本脚本（也可以不手动删，系统会清）
rm -f /etc/uci-defaults/99_nginx_setup

exit 0

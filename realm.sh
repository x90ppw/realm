#!/bin/bash
# ============================================================
# Realm 中转管理脚本（端口转发： 本机监听端口 -> 远程 IP:端口）
# 用法： bash realm.sh   然后按菜单操作
# 规则保存在 /etc/realm/rules.conf，重启不丢（systemd 托管）
# ============================================================
set -u

REALM_BIN="/usr/local/bin/realm"
CONF_DIR="/etc/realm"
RULES_FILE="$CONF_DIR/rules.conf"
TOML_FILE="$CONF_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"

red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }

[[ $EUID -ne 0 ]] && { red "请用 root 运行： sudo bash realm.sh"; exit 1; }
command -v systemctl >/dev/null 2>&1 || { red "未找到 systemd，此脚本不适用"; exit 1; }

mkdir -p "$CONF_DIR"
touch "$RULES_FILE"

# ---------- 安装 ----------
install_realm() {
    if [[ -x "$REALM_BIN" ]]; then
        green "realm 已安装：$($REALM_BIN --version 2>/dev/null || echo ok)"
        return 0
    fi
    local arch asset url tmp
    arch=$(uname -m)
    case "$arch" in
        x86_64)        asset="realm-x86_64-unknown-linux-gnu.tar.gz" ;;
        aarch64|arm64) asset="realm-aarch64-unknown-linux-gnu.tar.gz" ;;
        *) red "不支持的架构：$arch"; return 1 ;;
    esac
    url="https://github.com/zhboner/realm/releases/latest/download/$asset"
    tmp=$(mktemp -d)
    yellow "下载 realm（$arch）..."
    if ! curl -fL --retry 3 -o "$tmp/realm.tar.gz" "$url"; then
        red "下载失败，请检查服务器能否访问 GitHub"
        rm -rf "$tmp"; return 1
    fi
    tar -xzf "$tmp/realm.tar.gz" -C "$tmp" || { red "解压失败"; rm -rf "$tmp"; return 1; }
    install -m 755 "$tmp/realm" "$REALM_BIN" || { red "安装失败"; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    green "安装完成：$($REALM_BIN --version 2>/dev/null || echo realm)"
}

write_service() {
    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Realm Relay Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ---------- 配置生成 ----------
gen_toml() {
    {
        echo "[network]"
        echo "no_tls = true"
        echo ""
        while IFS='|' read -r lp rip rp; do
            [[ -z "${lp:-}" ]] && continue
            echo "[[endpoints]]"
            echo "listen = \"0.0.0.0:$lp\""
            echo "remote = \"$rip:$rp\""
            echo ""
        done < "$RULES_FILE"
    } > "$TOML_FILE"
}

apply_rules() {
    gen_toml
    write_service
    if [[ ! -s "$RULES_FILE" ]]; then
        systemctl stop realm 2>/dev/null
        yellow "当前没有转发规则，服务已停止"
        return 0
    fi
    systemctl enable realm >/dev/null 2>&1
    systemctl restart realm
    sleep 1
    if systemctl is-active --quiet realm; then
        green "已生效，realm 正在运行"
    else
        red "realm 启动失败，看日志： journalctl -u realm -n 30"
    fi
}

open_firewall() {
    local port=$1
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1
        ufw allow "$port"/udp >/dev/null 2>&1
        echo "已在 ufw 放行 $port"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$port"/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port="$port"/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo "已在 firewalld 放行 $port"
    fi
    yellow "提醒：云厂商控制台的安全组也要放行 $port（TCP+UDP），脚本管不了那一层"
}

# ---------- 规则操作 ----------
list_rules() {
    if [[ ! -s "$RULES_FILE" ]]; then
        yellow "（暂无转发规则）"
        return
    fi
    local i=0
    echo "----------------------------------------"
    while IFS='|' read -r lp rip rp; do
        [[ -z "${lp:-}" ]] && continue
        i=$((i+1))
        printf "%2d) 本机 :%s  ->  %s:%s\n" "$i" "$lp" "$rip" "$rp"
    done < "$RULES_FILE"
    echo "----------------------------------------"
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

add_rule() {
    install_realm || return
    local lp rip rp
    read -rp "本机监听端口（如 25001）: " lp
    valid_port "$lp" || { red "端口不合法"; return; }
    if grep -q "^$lp|" "$RULES_FILE"; then
        red "端口 $lp 已有转发规则，先删掉再加"; return
    fi
    read -rp "远程服务器 IP（如大阪 1.2.3.4）: " rip
    [[ "$rip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { red "IP 格式不对"; return; }
    read -rp "远程节点端口: " rp
    valid_port "$rp" || { red "端口不合法"; return; }
    echo "$lp|$rip|$rp" >> "$RULES_FILE"
    green "已添加：本机 :$lp -> $rip:$rp"
    apply_rules
    open_firewall "$lp"
    green "客户端把节点地址改成： 本机公网IP:$lp ，其余参数不动"
}

del_rule() {
    list_rules
    [[ -s "$RULES_FILE" ]] || return
    local n total
    read -rp "输入要删除的序号（0 取消）: " n
    [[ "$n" == "0" || -z "$n" ]] && return
    total=$(grep -c . "$RULES_FILE" || true)
    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > total )); then
        red "序号不对"; return
    fi
    local removed
    removed=$(sed -n "${n}p" "$RULES_FILE")
    sed -i "${n}d" "$RULES_FILE"
    green "已删除：$removed"
    apply_rules
}

# ---------- BBR ----------
enable_bbr() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        green "BBR 已开启"; return
    fi
    grep -q "tcp_congestion_control" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    grep -q "default_qdisc" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    sysctl net.ipv4.tcp_congestion_control
}

# ---------- 卸载 ----------
uninstall_realm() {
    read -rp "确认卸载 realm 并删除全部转发规则？(y/N): " yn
    [[ "$yn" =~ ^[Yy]$ ]] || return
    systemctl disable --now realm 2>/dev/null
    rm -f "$SERVICE_FILE" "$REALM_BIN"
    rm -rf "$CONF_DIR"
    systemctl daemon-reload
    green "已卸载"
}

status_realm() {
    systemctl status realm --no-pager -l 2>/dev/null | head -15 || yellow "服务未安装"
    echo ""
    list_rules
}

# ---------- 菜单 ----------
while true; do
    echo ""
    green "====== Realm 中转管理 ======"
    echo " 1) 添加转发"
    echo " 2) 查看转发列表"
    echo " 3) 删除转发"
    echo " 4) 查看服务状态"
    echo " 5) 开启 BBR"
    echo " 6) 卸载"
    echo " 0) 退出"
    read -rp "选择: " choice
    case "$choice" in
        1) add_rule ;;
        2) list_rules ;;
        3) del_rule ;;
        4) status_realm ;;
        5) enable_bbr ;;
        6) uninstall_realm ;;
        0) exit 0 ;;
        *) red "输入不对" ;;
    esac
done

#!/usr/bin/env bash
# Xray VLESS + Reality + xtls-rprx-vision 一键安装脚本
# 用法:
#   bash install-reality.sh                      # 默认 443 端口, 伪装 www.microsoft.com
#   PORT=8443 DEST=www.apple.com bash install-reality.sh
#   bash install-reality.sh info                 # 重新显示节点信息
#   bash install-reality.sh uninstall            # 卸载
set -euo pipefail

PORT="${PORT:-443}"
DEST="${DEST:-www.microsoft.com}"
CONF_DIR="/usr/local/etc/xray"
CONF="${CONF_DIR}/config.json"
INFO_FILE="/root/xray-reality-info.txt"

red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
blue()  { echo -e "\033[36m$*\033[0m"; }

[[ $EUID -eq 0 ]] || { red "请使用 root 运行"; exit 1; }

ACTION="${1:-install}"

if [[ "$ACTION" == "info" ]]; then
  [[ -f "$INFO_FILE" ]] && cat "$INFO_FILE" || red "未找到节点信息, 请先安装"
  exit 0
fi

if [[ "$ACTION" == "uninstall" ]]; then
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
  rm -f "$INFO_FILE"
  green "已卸载 Xray"
  exit 0
fi

# ---------- 1. 安装依赖 ----------
blue "[1/7] 安装依赖..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y >/dev/null
  apt-get install -y curl openssl ca-certificates >/dev/null
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl openssl ca-certificates >/dev/null
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl openssl ca-certificates >/dev/null
else
  red "不支持的系统, 请使用 Debian/Ubuntu/CentOS 系"; exit 1
fi

# ---------- 2. 检查端口 ----------
blue "[2/7] 检查端口 ${PORT}..."
if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
  if ! systemctl is-active --quiet xray 2>/dev/null; then
    red "端口 ${PORT} 已被占用, 请换端口: PORT=8443 bash $0"; exit 1
  fi
fi

# ---------- 3. 检查伪装目标 ----------
blue "[3/7] 检查伪装目标 ${DEST} (TLS1.3 + h2)..."
CHECK="$(echo | timeout 8 openssl s_client -connect "${DEST}:443" -servername "${DEST}" -tls1_3 -alpn h2 2>/dev/null || true)"
if ! grep -q "TLSv1.3" <<<"$CHECK" || ! grep -q "ALPN protocol: h2" <<<"$CHECK"; then
  red "警告: ${DEST} 可能不支持 TLS1.3/h2, 或本机无法访问, 建议换一个 DEST"
  read -r -p "仍要继续吗? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || exit 1
fi

# ---------- 4. 安装 Xray ----------
blue "[4/7] 安装/更新 Xray..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
command -v xray >/dev/null 2>&1 || { red "Xray 安装失败"; exit 1; }
green "Xray 版本: $(xray version | head -n1)"

# ---------- 5. 生成参数 ----------
blue "[5/7] 生成密钥和 UUID..."
UUID="$(xray uuid)"
KEYS="$(xray x25519)"
# 兼容新旧版本输出: 旧版 "Private key/Public key", 新版 "PrivateKey/Password"
PRIV="$(echo "$KEYS" | grep -iE '^private' | awk -F': *' '{print $2}' | tr -d ' \r')"
PUB="$(echo "$KEYS"  | grep -iE '^(public|password)' | awk -F': *' '{print $2}' | tr -d ' \r')"
SID="$(openssl rand -hex 8)"
[[ -n "$PRIV" && -n "$PUB" ]] || { red "密钥解析失败, 原始输出:"; echo "$KEYS"; exit 1; }

# ---------- 6. 写入配置 ----------
blue "[6/7] 写入配置..."
mkdir -p "$CONF_DIR"
[[ -f "$CONF" ]] && cp "$CONF" "${CONF}.bak.$(date +%s)"
cat > "$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:443",
          "xver": 0,
          "serverNames": ["${DEST}"],
          "privateKey": "${PRIV}",
          "shortIds": ["${SID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

xray run -test -config "$CONF" >/dev/null || { red "配置校验失败"; exit 1; }

# ---------- 7. 启动 + 防火墙 + BBR ----------
blue "[7/7] 启动服务并放行防火墙..."
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { red "Xray 启动失败, 查看日志: journalctl -u xray -e --no-pager"; exit 1; }

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" >/dev/null
fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
  firewall-cmd --reload >/dev/null
fi

if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != "bbr" ]]; then
  grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || {
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  }
  sysctl -p >/dev/null 2>&1 || true
fi

# ---------- 输出节点信息 ----------
IP="$(curl -fsS4 --max-time 6 https://api.ipify.org 2>/dev/null || curl -fsS4 --max-time 6 https://ifconfig.me 2>/dev/null || true)"
[[ -n "$IP" ]] || IP="$(curl -fsS6 --max-time 6 https://api64.ipify.org 2>/dev/null || echo "你的服务器IP")"
HOST="$IP"; [[ "$IP" == *:* ]] && HOST="[${IP}]"

LINK="vless://${UUID}@${HOST}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp#Reality-${IP}"

cat > "$INFO_FILE" <<EOF
==================== 节点信息 ====================
地址 (Address)    : ${IP}
端口 (Port)       : ${PORT}
UUID              : ${UUID}
流控 (Flow)       : xtls-rprx-vision
传输 (Network)    : tcp
安全 (Security)   : reality
SNI               : ${DEST}
指纹 (Fingerprint): chrome
公钥 (PublicKey)  : ${PUB}
ShortId           : ${SID}

分享链接:
${LINK}
=================================================
EOF

echo
green "安装完成!"
cat "$INFO_FILE"
echo
echo "节点信息已保存到: ${INFO_FILE}  (再次查看: bash $0 info)"
echo "查看日志: journalctl -u xray -e --no-pager"
echo "提醒: 云厂商控制台的安全组也要放行 TCP ${PORT}"

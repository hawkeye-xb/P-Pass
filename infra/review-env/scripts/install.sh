#!/usr/bin/env bash
# 审核配对页 —— 服务器侧安装脚本（幂等，可重跑）
#
# 用法：
#   sudo PPASS_REVIEW_PASSWORD='<密码>' ./install.sh \
#        --host pair.example.com \        # 对外域名（CF 一级子域）
#        --origin-sni pair-origin.example.com \  # 源站证书域名（可 == --host）
#        [--user review] [--port 8787] [--ipc-token /var/lib/ppass-review/p-pass/ipc.token]
#        [--http-listen 80] [--https-listen 443]   # 443 已被别的服务占用时改成如 127.0.0.1:9443
#
# 不做的事（刻意留给人）：
#   - 签证书：源站用自签（本脚本生成），不需要 Let's Encrypt
#   - 建 Cloudflare Tunnel：见 scripts/cf-tunnel.py
#   - 装 daemon 二进制：从 dogfood 产物或 CI 取，见 README「daemon」
set -euo pipefail

HOST=""; USER_NAME="review"; PORT="8787"
IPC_TOKEN="/var/lib/ppass-review/p-pass/ipc.token"
HTTP_LISTEN="80"; HTTPS_LISTEN="443"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) USER_NAME="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --ipc-token) IPC_TOKEN="$2"; shift 2 ;;
    --http-listen) HTTP_LISTEN="$2"; shift 2 ;;
    --https-listen) HTTPS_LISTEN="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" = "0" ] || { echo "要 root" >&2; exit 1; }
[ -n "$HOST" ] || { echo "缺 --host" >&2; exit 2; }

# 1. 依赖
for b in python3 qrencode htpasswd nginx curl; do
  command -v "$b" >/dev/null || { echo "缺依赖: ${b}（apt-get install -y qrencode apache2-utils nginx curl python3）" >&2; exit 1; }
done

# 2. 页面后端
install -d -m 755 /opt/ppass-review/pairpage
install -m 644 "$HERE/pairpage/server.py" "$HERE/pairpage/index.html" "$HERE/pairpage/samples.html" /opt/ppass-review/pairpage/
install -d -m 755 /opt/ppass-review/pairpage/samples
install -m 644 "$HERE"/pairpage/samples/*.jpg /opt/ppass-review/pairpage/samples/
install -d -m 755 /var/lib/ppass-review
# #1115：Linux 上库位置的正本是平台 config.toml；没有它 daemon 进「未配置」状态、等窗口程序
# 配置（无界面机器上没人配）。库仍放平台目录本身（与以前同一位置，ipc.token 路径不变）；
# 已有就不动。
mkdir -p /var/lib/ppass-review/p-pass
[ -e /var/lib/ppass-review/p-pass/config.toml ] \
  || printf 'data_dir = "%s"\n' /var/lib/ppass-review/p-pass > /var/lib/ppass-review/p-pass/config.toml

# 3. systemd
install -m 644 "$HERE/systemd/ppass-review.service" /etc/systemd/system/
install -m 644 "$HERE/systemd/ppass-pairpage.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now ppass-review.service

# 等 daemon 写出 ipc.token —— 页面后端要靠它找 socket
for _ in $(seq 1 50); do [ -s "$IPC_TOKEN" ] && break; sleep 0.2; done
[ -s "$IPC_TOKEN" ] || { echo "daemon 没写出 ${IPC_TOKEN}，先看 journalctl -u ppass-review" >&2; exit 1; }

# 4. 页面服务（端口写进 unit 之外的地方容易忘，这里直接生成 drop-in）
install -d -m 755 /etc/systemd/system/ppass-pairpage.service.d
printf '[Service]\nEnvironment=PORT=%s\nEnvironment=PPF_IPC_TOKEN_FILE=%s\n' "$PORT" "$IPC_TOKEN" \
  > /etc/systemd/system/ppass-pairpage.service.d/override.conf
systemctl daemon-reload
systemctl enable --now ppass-pairpage.service

# 5. 账号
# 密码只出现在执行期：不落仓库、不落文档。没给就现生成一个并打印一次。
PW="${PPASS_REVIEW_PASSWORD:-}"
if [ -z "$PW" ]; then
  PW="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
  echo "生成密码（只打印这一次，请存进 App Store Connect 的审核信息）：$PW"
fi
htpasswd -cb /etc/nginx/.htpasswd-pair "$USER_NAME" "$PW" >/dev/null
# nginx worker 不是 root —— 640 + www-data 组是能读又不过度开放的最小值
chown root:www-data /etc/nginx/.htpasswd-pair
chmod 640 /etc/nginx/.htpasswd-pair

# 6. nginx：自签证书 + 站点 + 限流 + CF 真实 IP
install -d -m 700 /etc/nginx/selfsigned
CERT_BASE="/etc/nginx/selfsigned/$HOST"
if [ ! -f "$CERT_BASE.crt" ]; then
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$CERT_BASE.key" -out "$CERT_BASE.crt" \
    -subj "/CN=$HOST" -addext "subjectAltName=DNS:$HOST" 2>/dev/null
  chmod 600 "$CERT_BASE.key"
fi
# 只给端口 ⇒ IPv4 + IPv6 都听（原默认行为）；给了 地址:端口 ⇒ 只听那一个（例：443 被占时只给隧道用的 127.0.0.1:9443）
listen_lines() {  # $1=值 $2=额外参数
  case "$1" in
    *[!0-9]*) printf 'listen %s%s;' "$1" "$2" ;;
    *) printf 'listen %s%s;\\n    listen [::]:%s%s;' "$1" "$2" "$1" "$2" ;;
  esac
}
sed -e "s/__PUBLIC_HOST__/$HOST/g" -e "s#__SELF_SIGNED_BASE__#$CERT_BASE#g" \
    -e "s#__HTTP_LISTEN__#$(listen_lines "$HTTP_LISTEN" "")#" \
    -e "s#__HTTPS_LISTEN__#$(listen_lines "$HTTPS_LISTEN" " ssl http2")#" \
  "$HERE/nginx/pair.conf.template" > /etc/nginx/sites-available/pair
ln -sf /etc/nginx/sites-available/pair /etc/nginx/sites-enabled/pair
install -m 644 "$HERE/nginx/ppass-limit.conf" /etc/nginx/conf.d/ppass-limit.conf

# Cloudflare 段：走 Tunnel 时源站对端恒为边缘 IP，必须还原真实客户端（限流/日志才有意义）
{
  for ip in $(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v4) \
            $(curl -fsS --max-time 10 https://www.cloudflare.com/ips-v6); do
    echo "set_real_ip_from $ip;"
  done
  echo 'real_ip_header CF-Connecting-IP;'
  echo 'real_ip_recursive on;'
} > /etc/nginx/conf.d/ppass-cf-realip.conf

nginx -t
systemctl reload nginx

# 7. 收尾自检（本机，不经过公网域名：这台机器上没有 hairpin NAT）
HTTPS_PORT="${HTTPS_LISTEN##*:}"
echo "--- 自检 ---"
curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/healthz" && echo
curl -sk --max-time 5 --resolve "$HOST:$HTTPS_PORT:127.0.0.1" -o /dev/null \
     -w "无凭据 %{http_code}（期望 401）\n" "https://$HOST:$HTTPS_PORT/"
curl -sk --max-time 5 --resolve "$HOST:$HTTPS_PORT:127.0.0.1" -u "$USER_NAME:$PW" -o /dev/null \
     -w "带凭据 %{http_code}（期望 200）\n" "https://$HOST:$HTTPS_PORT/"
echo "装完了。对外的 Cloudflare Tunnel 与 DNS 见 scripts/cf-tunnel.py。"

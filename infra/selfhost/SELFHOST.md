# SELFHOST — 自建 P-Pass 全套（T-063 / T-063b）

> 承诺：**云端三件套全部可自建**（隔离方案 §1.1）。这一页让任何人在一台
> ~$5/月的 VPS 上跑起自己的中继 + 会合 + 反代，客户端改三行配置即可指向。
>
> Promise: every cloud component is self-hostable. This page gets you from
> zero to a working relay + rendezvous on one ~$5/mo VPS.
>
> ✅ 2026-08-03 T-063b 真机验证：Vultr SG 全流程走通（DNS → certbot → compose
> → Kuma 探针 → dogfood-smoke）。本文档按实测结果修订，照做即可，无隐藏坑。

## 组件 / Components

| 组件 | 镜像/来源 | 端口 | 作用 |
|---|---|---|---|
| iroh-relay | **自建 glibc 镜像**（`infra/selfhost/relay/Dockerfile`，debian + 官方 GitHub release 二进制） | 8443 TCP + 7842 UDP | 中继兜底（NAT 打洞失败时转发加密流量） |
| rendezvous | 本仓库 Dockerfile（Miniflare/workerd，**glibc base**） | 8787（caddy 反代到 443） | 配对会合（短码信封交换，T-060） |
| caddy | `caddy:2-alpine` | 80/443 | 自动 TLS 反代 |
| pkarr | （Phase 2，profile 未开） | — | 自建发现——当前客户端 QR 自带地址，暂不需要 |

> ⚠️ **relay 不用官方镜像**（T-063b 实测）：`n0computer/iroh-relay:v1.0.3`
> 是 musl 构建，noq-udp 的 cmsg 对齐断言在 musl 上 panic（QUIC 一跑 SIGSEGV，
> 容器 Restarting (139)）。官方 GitHub release 的 glibc 二进制无此问题。
> 构建自建镜像前先下载二进制：
> ```bash
> cd infra/selfhost/relay
> wget https://github.com/n0-computer/iroh/releases/download/v1.0.3/iroh-relay-v1.0.3-x86_64-unknown-linux-gnu.tar.gz
> tar xzf iroh-relay-v1.0.3-*.tar.gz && cp iroh-relay .
> ```

## 从零步骤 / From zero

**1. 买 VPS**（Hetzner CX22 / Vultr，Ubuntu 24.04，~$4-6/月）。本机自建测试：
`docker compose up` 即可，跳过本步。⚠️ 不用中国大陆区域的机器/域名。

**2. 域名 DNS**：给两个子域加 A 记录指向 VPS IP（示例 `relay.example.com` /
`rendezvous.example.com`）。证书签发需要域名真实解析。

**3. 登录 VPS，装 docker + certbot**：
```bash
curl -fsSL https://get.docker.com | sh
apt install -y certbot
```

**4. 取仓库 + 配置**：
```bash
git clone https://github.com/hawkeye-xb/P-Pass.git
cd P-Pass/infra/selfhost
cp .env.example .env                     # 编辑 RENDEZVOUS_DOMAIN
cp relay-config.example.toml relay-config.toml   # 编辑 tls.hostname
# relay glibc 二进制（官方镜像 musl 有 panic，见上）：
cd relay && wget https://github.com/n0-computer/iroh/releases/download/v1.0.3/iroh-relay-v1.0.3-x86_64-unknown-linux-gnu.tar.gz \
  && tar xzf iroh-relay-v1.0.3-*.tar.gz && cp iroh-relay . && cd ..
```

**5. 签 relay 证书（T-063b 修正：不用内置 LetsEncrypt）**：
relay 内置 LetsEncrypt 需要 80/443 做 ACME 挑战，但这两个端口被 caddy
（或本机其他服务）占用，**永远签不出**。正确路径 = certbot standalone
（趁 caddy 还没起来、80 空闲时签）：
```bash
# 先停掉任何占用 80 的服务（全新 VPS 没有；已有服务就先 systemctl stop 它）
certbot certonly --standalone --non-interactive --agree-tos -m you@example.com -d relay.example.com
```
证书落在 `/etc/letsencrypt/live/relay.example.com/`，relay 容器只读挂载。
续期：`certbot renew` 默认定时器已装（`certbot.timer`），但 standalone 续期时
80 必须空闲——若 caddy 常驻，首签后切换到 webroot（见下「运维·证书」，一条命令）。

**6. 起服务**：
```bash
docker compose up -d --build     # relay + rendezvous + caddy 全套
docker compose up -d relay       # 只要 relay（rendezvous/caddy 用官方 CF Workers）
docker compose ps                # 三个服务都 healthy
```
> ⚠️ 自建 rendezvous 的镜像用 glibc base（node:22-slim）。alpine 上 workerd
> 二进制 spawn 会 ENOENT（musl 缺 glibc interpreter），2026-08-03 VPS 实测。

**7. 验证**：
```bash
curl -sI https://<relay 域名>:8443/healthz     # → 200（relay 健康端点）
curl -s https://$RENDEZVOUS_DOMAIN/            # → {"ok":true,"service":"ppass-rendezvous"}（rendezvous 已起时）
```

**8. 客户端指向自建端点**（daemon `config.toml`）：
```toml
relay_urls = ["https://relay.example.com:8443"]
rendezvous_url = "https://rendezvous.example.com"
```

**9. Kuma 探针**（T-064）：`infra/relay/kuma.example.yml` 导入 Uptime Kuma →
relay 探针 URL 填 `https://<relay 域名>:8443/healthz`，期望 200。

## 运维 / Operations

- **防火墙**：只开 22、80、443、8443、7842/udp。cloud-init 模板已含
  `ufw allow` + `ufw --force enable`（T-063b 修正：旧模板只写 profiles 从不
  enable，防火墙从未生效）。手动环境：
  ```bash
  ufw allow ssh && ufw allow 80/tcp && ufw allow 443/tcp
  ufw allow 8443/tcp && ufw allow 7842/udp && ufw --force enable
  ```
- **证书**：relay 用 certbot Manual 证书（`/etc/letsencrypt`），自动续期走
  `certbot.timer`。续期路径按部署形态二选一（T-063b review 修正：旧文档的
  webroot 路由并不存在、manual DNS 又无法自动续期，两条都跑不通）：
  - **只跑 relay**（80 空闲，cloud-init 默认形态）：首签就是 standalone，
    `certbot renew` 自动复用同一方式，零额外配置。
  - **全套自建**（caddy 占 80）：首签后执行一次
    ```bash
    mkdir -p /var/www/certbot
    certbot certonly --webroot -w /var/www/certbot -d relay.example.com
    ```
    把该域名的续期方式切换为 webroot——Caddyfile 已配 `http://{$RELAY_DOMAIN}`
    的 challenge 应答、compose 已给 caddy 挂 `/var/www/certbot:ro`，此后
    `certbot.timer` 自动续期不再占 80。
  - 续期成功 = 新证书落盘 → relay 需要重启生效，推荐挂 deploy-hook 全自动：
    ```bash
    certbot renew --deploy-hook 'docker compose -f /opt/ppass/infra/selfhost/docker-compose.yml restart relay'
    ```
- **升级**：`git pull && docker compose up -d --build`。
- **监控**：Kuma 探针模板见 `infra/relay/`（T-064）；relay metrics 开 9090 端口
  可给 prometheus 抓（compose 里注释着）。
- **多区域**：想更稳就开两台（不同区域），客户端 `relay_urls` 列表里写两个，
  iroh 自动故障切换——relay 无状态，加容量就是多跑一个进程。

## 已知边界 / Known limits

- 单 VPS 上 relay HTTPS 走 8443（80/443 被 caddy 占用）——客户端 URL 要带端口。
- relay 证书必须 Manual（certbot）——内置 LetsEncrypt 在 80/443 被占时签不出
  （T-063b 实测）。
- 自建 rendezvous 用的是 Miniflare（workerd 内核，DO 语义与 CF 一致），
  官方端点仍推荐 CF Workers 免费档托管；两者可混用。
- shared_token 访问控制等客户端支持 relay auth token 后启用（当前 daemon
  config 无 token 字段）。
- pkarr 自建发现是 Phase 2（iroh 自定义 discovery 支持落地后）。

## 本地开发测试 / Local dev

本机（无嵌套虚拟化、跑不了 docker 的环境）等价验证路径：
```bash
# 1) 原生跑 relay dev 模式（HTTP，localhost:3340）
wget https://github.com/n0-computer/iroh/releases/download/v1.0.3/iroh-relay-v1.0.3-$(uname -m)-apple-darwin.tar.gz
tar xzf iroh-relay-v1.0.3-*.tar.gz && ./iroh-relay --dev &

# 2) daemon + testclient 全流程 smoke（relay 走本地）
PPF_RELAY_URLS="http://localhost:3340" tools/dogfood-smoke.sh

# 3) rendezvous 本地跑（可选）
cd infra/workers/rendezvous && npm i && npx wrangler dev --port 8787
```

## 自建≠零官方依赖 / What still needs n0/Cloudflare

iroh 客户端的**发现**默认走 n0 官方 DNS 发现（pkarr 未自建前）。配对用 QR
地址段（`&a=<addr>`）时零发现依赖；离线/纯内网场景完全自洽。

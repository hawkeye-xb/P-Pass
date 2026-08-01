# SELFHOST — 自建 P-Pass 全套（T-063）

> 承诺：**云端三件套全部可自建**（隔离方案 §1.1）。这一页让任何人在一台
> ~$5/月的 VPS 上跑起自己的中继 + 会合 + 反代，客户端改三行配置即可指向。
>
> Promise: every cloud component is self-hostable. This page gets you from
> zero to a working relay + rendezvous on one ~$5/mo VPS.

## 组件 / Components

| 组件 | 镜像/来源 | 端口 | 作用 |
|---|---|---|---|
| iroh-relay | `n0computer/iroh-relay:v1.0.3`（官方） | 8443 TCP + 7842 UDP | 中继兜底（NAT 打洞失败时转发加密流量） |
| rendezvous | 本仓库 Dockerfile（Miniflare/workerd） | 8787（caddy 反代到 443） | 配对会合（短码信封交换，T-060） |
| caddy | `caddy:2-alpine` | 80/443 | 自动 TLS 反代 |
| pkarr | （Phase 2，profile 未开） | — | 自建发现——当前客户端 QR 自带地址，暂不需要 |

## 从零步骤 / From zero

**1. 买 VPS**（Hetzner CX22 / Vultr，Ubuntu 24.04，~$4-6/月）。本机自建测试：
`docker compose up` 即可，跳过本步。

**2. 域名 DNS**：给两个子域加 A 记录指向 VPS IP（示例 `relay.example.com` /
`rendezvous.example.com`）。LetsEncrypt 需要域名真实解析。

**3. 登录 VPS，装 docker**：
```bash
curl -fsSL https://get.docker.com | sh
```

**4. 取仓库 + 配置**：
```bash
git clone https://github.com/hawkeye-xb/P-Pass.git
cd P-Pass/infra/selfhost
cp .env.example .env                     # 编辑 RENDEZVOUS_DOMAIN
cp relay-config.example.toml relay-config.toml   # 编辑 tls.hostname
```

**5. 起服务**：
```bash
docker compose up -d --build
docker compose ps                        # 三个服务都 healthy
```

**6. 验证**：
```bash
curl -s https://$RENDEZVOUS_DOMAIN/                  # → {"ok":true,"service":"ppass-rendezvous"}
curl -sI https://relay.example.com:8443              # → 200（relay 的 HTTP 端点）
```

**7. 客户端指向自建端点**（daemon `config.toml`）：
```toml
relay_urls = ["https://relay.example.com:8443"]
rendezvous_url = "https://rendezvous.example.com"
```

## 运维 / Operations

- **防火墙**：只开 22、80、443、8443、7842/udp。
- **证书**：relay 用内置 LetsEncrypt（证书在 `relay-certs` 卷，自动续期）；
  caddy 自动管理自己的证书。续期失败 = 卷没持久化，检查 `docker compose down` 时
  别加 `-v`。
- **升级**：`git pull && docker compose up -d --build`。
- **监控**：Kuma 探针模板见 `infra/relay/`（T-064）；relay metrics 开 9090 端口
  可给 prometheus 抓（compose 里注释着）。
- **多区域**：想更稳就开两台（不同区域），客户端 `relay_urls` 列表里写两个，
  iroh 自动故障切换——relay 无状态，加容量就是多跑一个进程。

## 已知边界 / Known limits

- 单 VPS 上 relay HTTPS 走 8443（80/443 被 caddy 占用）——客户端 URL 要带端口。
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

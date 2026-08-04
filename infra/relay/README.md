# infra/relay — 官方 relay 部署模板（T-064 / T-063b）

> 供 H-07（人类任务：买 3 台 VPS + DNS）使用。**本目录只含占位符模板，
> 无真实 IP/域名/凭据**——真实值在私有仓 `ppf-ops/deploy/relay/`
> （服务器清单 + caddy 生产配置 + 部署脚本）。

This directory holds placeholder deployment templates for the official
P-Pass relays (US/EU/AP). Real values live in the private ops repo.

## 文件 / Files

| 文件 | 用途 |
|---|---|
| `cloud-init.example.yml` | VPS 初始化模板：装 docker + 拉仓库 + certbot 证书 + 起 relay（占位域名 `relay-{region}.example.com`） |
| `kuma.example.yml` | Uptime Kuma 探针配置模板（3 区域 relay + rendezvous 健康检查） |

## 区域规划 / Region plan（H-07）

| 区域 | 域名（规划，H-01） | 供应商（H-07 采购） |
|---|---|---|
| US | `relay-us.p-pass.hawkeye-xb.com` | Hetzner 或 Vultr |
| EU | `relay-eu.p-pass.hawkeye-xb.com` | Hetzner |
| AP | `relay-ap.p-pass.hawkeye-xb.com` | Vultr |

relay 无状态：每区域一个进程，客户端 `relay_urls` 列表自动故障切换。
**注意**：daemon 默认 `relay_urls = []`（2026-07-31 用户裁决，H-07 部署前
空列表防毒害路径协商）；H-07 上线后由用户在私有仓部署记录里把三区域 URL
写回 `config/endpoints.default.toml`（或客户端 config 覆盖）。

## 使用 / Usage（H-07 时）

1. 买 VPS（每台 ~$4-6/月），记下 IP
2. DNS：`relay-{region}.p-pass.hawkeye-xb.com` → A 记录（私有仓 `ppf-ops/deploy/dns.md` 记账）
3. 用 cloud-init 模板开机器（或手动执行其中命令）——⚠️ 替换占位符为真实域名
4. Kuma 探针模板导入（私有仓 monitoring 配置）
5. 客户端默认端点自动生效（无需改动 daemon 配置）

> T-063b 实测（2026-08-03，Vultr SG）：cloud-init 需在 compose up 前先
> `certbot certonly --standalone` 签 Manual 证书（relay 内置 LetsEncrypt 在
> 80/443 被占时签不出）；ufw 必须显式 allow + enable。详见 `infra/selfhost/SELFHOST.md`。

## 失败预案 / Failure（见 runbook `relay-down.md`）

Kuma 告警 → ssh 看 relay 日志 → `docker compose restart relay` → 客户端自动切换
到其他区域 relay（无状态，无需协调）。

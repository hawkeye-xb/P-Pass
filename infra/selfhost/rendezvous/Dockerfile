# P-Pass rendezvous worker, self-hosted (T-063 / T-063b).
#
# Runs the Cloudflare Worker on Miniflare — Cloudflare's own workerd-based
# local runtime — so the Durable Object semantics are identical to CF Workers.
# Family scale is trivially one process; the official hosted option (CF
# Workers free tier) remains the recommended hosting for the official
# endpoints. `wrangler dev` serves the worker + DO from the committed
# wrangler.toml (no account needed in local mode).
#
# ⚠️ T-063b 实测修正：必须用 glibc base（node:22-slim），不能用 node:22-alpine。
# workerd 官方二进制是 glibc 构建，在 musl/alpine 上 spawn 报 ENOENT
# （ELF interpreter /lib64/ld-linux-x86-64.so.2 缺失），wrangler dev 无法启动
# （VPS 实测 2026-08-03：alpine → "spawn .../workerd ENOENT"；slim → Ready）。
#
# 自建 rendezvous：用 Miniflare（workerd 内核）跑同一个 Worker，DO 语义与
# Cloudflare Workers 完全一致。家庭规模单进程绰绰有余；官方端点仍推荐
# CF Workers 免费档托管。

FROM node:22-slim

WORKDIR /app

# wrangler 是 devDependency（本 worker 零运行时依赖）——容器内全量安装。
COPY infra/workers/rendezvous/package.json infra/workers/rendezvous/package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY infra/workers/rendezvous/ ./

EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8787/ >/dev/null 2>&1 || exit 1

CMD ["npx", "wrangler", "dev", "--ip", "0.0.0.0", "--port", "8787"]

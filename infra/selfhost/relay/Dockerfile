# P-Pass self-host relay image (T-063 / T-063b).
#
# ⚠️ 为什么不用官方镜像：`n0computer/iroh-relay:v1.0.3` 是 musl/Alpine 构建，
# noq-udp 1.1.0 的 cmsg 对齐断言在 musl 上 panic（VPS 实测 2026-08-03：
# `assertion failed: align_of::<T>() <= align_of::<C>()` at noq-udp/src/cmsg/mod.rs:81，
# QUIC 一跑就 SIGSEGV，容器反复 Restarting (139)）。官方 GitHub release 的
# glibc 二进制无此问题（VPS 实测稳定运行）。
#
# 本镜像：debian (glibc) + 官方 GitHub release glibc 二进制。
# T-063b review 修复：二进制在构建期下载并 sha256 校验——仓库自足，
# 全新 VPS 只需 `docker compose up -d --build relay`，不再依赖手放文件
# （旧版 COPY 本地二进制，而该文件被 .gitignore 排除，cloud-init 路径必断）。

FROM debian:bookworm-slim AS fetch

ARG RELAY_VERSION=v1.0.3
# 官方 release 产物的 SHA-256（升级 RELAY_VERSION 时必须同步更新——
# 校验失败即构建失败，宁可响亮失败也不跑没验过的二进制）。
ARG RELAY_SHA256=ad7de882c4825a851b38869a3f1622b674cb65f344304e432f862ddf72d6b39a

RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    wget -qO /tmp/iroh-relay.tgz \
      "https://github.com/n0-computer/iroh/releases/download/${RELAY_VERSION}/iroh-relay-${RELAY_VERSION}-x86_64-unknown-linux-gnu.tar.gz"; \
    echo "${RELAY_SHA256}  /tmp/iroh-relay.tgz" | sha256sum -c -; \
    tar -xzf /tmp/iroh-relay.tgz -C /tmp; \
    install -m 0755 /tmp/iroh-relay /usr/local/bin/iroh-relay

FROM debian:bookworm-slim

# healthcheck 用 wget（slim 镜像默认没有，显式装）
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /usr/local/bin/iroh-relay /usr/local/bin/iroh-relay

# 证书目录（compose 挂载 /etc/letsencrypt → /etc/iroh-relay/certs）
RUN mkdir -p /etc/iroh-relay/certs

EXPOSE 443 80 7842/udp

ENTRYPOINT ["/usr/local/bin/iroh-relay"]

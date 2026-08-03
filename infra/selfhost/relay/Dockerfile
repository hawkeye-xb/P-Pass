# P-Pass self-host relay image (T-063 / T-063b).
#
# ⚠️ 为什么不用官方镜像：`n0computer/iroh-relay:v1.0.3` 是 musl/Alpine 构建，
# noq-udp 1.1.0 的 cmsg 对齐断言在 musl 上 panic（VPS 实测 2026-08-03：
# `assertion failed: align_of::<T>() <= align_of::<C>()` at noq-udp/src/cmsg/mod.rs:81，
# QUIC 一跑就 SIGSEGV，容器反复 Restarting (139)）。官方 GitHub release 的
# glibc 二进制无此问题（`/opt/ppass/relay-bin/` 实测稳定运行）。
#
# 本镜像：debian (glibc) + 官方 GitHub release glibc 二进制。
# 构建前需要把二进制放进本目录（.gitignore 排除，或 CI 下载）：
#   wget https://github.com/n0-computer/iroh/releases/download/v1.0.3/iroh-relay-v1.0.3-x86_64-unknown-linux-gnu.tar.gz
#   tar xzf ... && cp iroh-relay ./iroh-relay
# 或用 build-arg RELAY_BIN 指向仓库外的二进制路径。

FROM debian:bookworm-slim

# healthcheck 用 wget（slim 镜像默认没有，显式装）
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY iroh-relay /usr/local/bin/iroh-relay
RUN chmod +x /usr/local/bin/iroh-relay

# 证书目录（compose 挂载 /etc/letsencrypt → /etc/iroh-relay/certs）
RUN mkdir -p /etc/iroh-relay/certs

EXPOSE 443 80 7842/udp

ENTRYPOINT ["/usr/local/bin/iroh-relay"]

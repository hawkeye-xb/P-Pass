# 狗粮机部署手册（Mac mini，agent 可执行）

目标：在家里 Mac mini 上把 P-Pass daemon 以生产形态跑起来，
并用接口剧本完成验收。全程命令行，无需 GUI。

## 0. 前置

- Rust 工具链（`rustup` stable）。没有则：
  `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y`
- 网络注意：Mac mini 宿主机直跑（**不要进 UTM 虚机**——H-04 实证
  VM 双层 NAT 会毁掉直连），Clash 需规则模式或对 UDP 41145 放行。

## 1. 构建

```bash
git clone https://github.com/hawkeye-xb/P-Pass.git && cd P-Pass
cargo build --release -p daemon -p testclient
```

## 2. 启动 daemon

```bash
mkdir -p ~/ppf-library
PPF_DATA_DIR=~/ppf-library \
PPF_TELEMETRY_ENABLED=false \
PPF_RELAY_URLS="" \
  nohup ./target/release/daemon > ~/ppf-daemon.log 2> ~/ppf-daemon.err &
sleep 3 && cat ~/ppf-daemon.log
```

> `PPF_RELAY_URLS=""`：官方 relay 域名（H-01 规划）尚未部署（H-07），
> 留着会毒害连接协商——冒烟 #1 的实证教训。H-07 部署后移除此行。

启动输出里三样东西要记下来并回传：
1. `NodeId: <64hex>` —— 存储端身份；
2. `ppf://pair?...` —— 配对串（含地址，10 分钟有效；过期用 IPC
   `pairing.start` 再要一张）；
3. `ipc.token` 路径 —— 本机管理面凭证。

## 3. 本机自检（同机三进程冒烟）

```bash
tools/dogfood-smoke.sh /tmp/ppf-smoke
# 期望最后一行: DOGFOOD SMOKE: ALL GREEN
```

## 4. 双机验收（办公侧发起）

办公侧拿到第 2 步的配对串后：

```bash
# 办公 Mac，P-Pass 仓库根目录
./target/release/testclient pair --token '<ppf://pair?...>' --name '办公Mac'
# → Mac mini 侧 agent 经 IPC 确认:
#   python3 连 /tmp/<ipc.token第一行>，首行发 token，然后
#   {"id":"c","method":"pairing.confirm","params":{"accept":true}}
./target/release/testclient backup --files 200 --node <NodeId>
./target/release/testclient backup --files 200 --node <NodeId>   # 幂等，期望缺 0
./target/release/testclient browse --limit 50 --node <NodeId>
```

验收标准（与 tools/dogfood-smoke.sh 同源）：
- 配对成功且 Mac mini 白名单出现设备行；
- 两次 backup：第一次入库=去重后数，第二次缺 0 零传输；
- browse 分页无重复、缩略图可解码；
- IPC `device.revoke` 后办公侧 `revoke-check` 返回"被正确拒绝"。

## 5. 已知事项

- daemon 崩溃/重启后：库与索引完好（ADR-006 有守护测试），重新配对
  不需要——白名单在库里；但 QR 与 IPC 令牌是每次启动新发的。
- 日志级别：`RUST_LOG=debug` 重启可看连接细节；诊断包用 IPC
  `logs.export`（路径已脱敏，可直接外发）。

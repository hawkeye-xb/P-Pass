# 审核验证环境（Linux headless daemon + 配对页）

给 App Store 审核用的一套临时环境：一台 Linux 机器跑 P-Pass daemon（只存演示数据），
一个 HTTP 页面负责「生成配对二维码 / 看谁来配对 / 点允许」。审核员手里没有桌面端，
靠这套东西完成配对和备份。

**这不是正式服务**，口径见 [`DISCLAIMER.md`](DISCLAIMER.md)。

```
手机 App ──(n0 relay / QUIC)──> daemon ──(抽象命名空间 socket, IPC)──> server.py ──> nginx ──> Cloudflare Tunnel ──> 浏览器
```

三段各自独立，任何一段挂了都能单独换：

- `daemon`：仓库 CI 的 linux-x64 产物（`dogfood` release），systemd 常驻，数据在 `/var/lib/ppass-review`
- `pairpage/server.py`：标准库写的小后端，只做三个 IPC 调用
- `nginx + Tunnel`：对外唯一入口，Basic Auth 挡人

## 访问：国内 / 海外分别用哪个地址

两个地区**不是按网络做分流**，而是两台互相独立的演示机，各自有独立身份、独立库、可以单独关：

| 场景 | 用哪个地址 | 说明 |
|---|---|---|
| **海外（审核员）** | `https://review.<域>` | 审核员专用那台（放 SG）。地址与账号密码写进 App Store Connect 的「审核信息」，只给审核员 |
| **国内（我们自测）** | `https://pair-test.<域>` | 国内那台，只给我们自己用；不写进任何审核材料 |

**命名约定**：一个环境一个子域，名字里带语义，**不留裸 `pair`**——

- `pair-test` = 自测机（国内）
- `review` = 审核机（SG，给审核员）
- 以后加第三套（比如压测/回归）就继续 `xxx-test` / `xxx-staging`，不复用已有名字

理由：审核地址会被写进 Apple 的审核材料然后长期沉寂，一旦被别的环境复用，下次出事时「到底哪个环境」就说不清；
而自测机在仓库文档里出现频率高得多，名字里带 `test` 能挡住「把自测地址写进审核备注」这类错。

> 当前状态（2026-10-22）：只有国内这台（阿里云华北）已经跑通，审核员那台还没建（#1088 的服务器部分）。
> 如果先提审、SG 还没就绪：**在这台机器上再加一个 `review.` 子域指过来**（机器不换、名字换），
> 不要把 `pair-test` 的地址写进审核备注——名字是给未来的人看的，混用早晚要出事。

为什么不能「国内直连、海外走别的」：国内云上**未备案域名**会被拦截（见下方「坑」），
两个地区实际都只能经 Cloudflare 边缘访问；能区分的是**机器**，不是链路。

## 部署步骤

### 0. 前提

- Linux x64 机器（实测 Ubuntu 24.04，1C1.6G 够用）
- 一个 Cloudflare 托管域名，**一级子域**（`pair.example.com`；`pair.x.example.com` 没有免费边缘证书）

### 1. daemon 二进制（冻结用）

审核环境的原则是「提审前部署、审核期间不更新」。所以取一次产物、算 SHA、归档：

```bash
gh release download dogfood --repo hawkeye-xb/P-Pass \
  --pattern daemon --pattern testclient --pattern SHA256SUMS-linux-x64 --pattern BUILD_INFO-linux-x64 -D /tmp/ppf
sha256sum -c /tmp/ppf/SHA256SUMS-linux-x64
install -d /opt/ppass-review/bin /opt/ppass-review/archive
install -m 755 /tmp/ppf/daemon /tmp/ppf/testclient /opt/ppass-review/bin/
cp /tmp/ppf/SHA256SUMS-linux-x64 /tmp/ppf/BUILD_INFO-linux-x64 /opt/ppass-review/archive/
```

`BUILD_INFO-linux-x64` 里记着这条产物来自哪个 commit —— 出问题时要能说出「审核期间跑的是哪一份」。

已经部署过、只换二进制（不重跑第 2 步）时，先确认库位置文件在：#1115 起 Linux 上没有
`config.toml` 的 daemon 进「未配置」状态、不开库，审核页配不上对。第 2 步的 install.sh 会写它；
早于 #1115 部署的机器没有，补一次（库还在原来的位置）：

```bash
[ -e /var/lib/ppass-review/p-pass/config.toml ] \
  || printf 'data_dir = "%s"\n' /var/lib/ppass-review/p-pass | sudo tee /var/lib/ppass-review/p-pass/config.toml
sudo systemctl restart ppass-review.service
```

### 2. 页面 + 服务 + 账号 + nginx

```bash
sudo PPASS_REVIEW_PASSWORD='<想好的密码>' \
  infra/review-env/scripts/install.sh --host pair.example.com --origin-sni origin.example.com
```

脚本做：装页面到 `/opt/ppass-review`、建两个 systemd unit 并启动、写 htpasswd（`root:www-data` 640）、
生成 nginx 站点（Basic Auth + 限流 + noindex）、把 Cloudflare 段写进 `set_real_ip_from`、
最后本机自检（无凭据 401 / 带凭据 200）。

### 3. 证书（源站，自签就够）

源站只被 Cloudflare Tunnel 从 `127.0.0.1` 访问，浏览器看到的是 CF 边缘证书。所以源站用**自签证书**即可，
隧道的 ingress 里写 `noTLSVerify: true`：

```bash
install -d -m 700 /etc/nginx/selfsigned && cd /etc/nginx/selfsigned
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout pair-test.key -out pair-test.crt \
  -subj "/CN=pair-test.example.com" -addext "subjectAltName=DNS:pair-test.example.com"
```

好处：不依赖 Let's Encrypt、不会在审核窗口里过期、也不需要为了 80/443 被拦的机器折腾 DNS-01。
（如果哪天不走 Tunnel 而是直连公网，就得换回 LE —— 那时 80/443 的备案问题会一起回来。）

### 4. Tunnel + DNS

```bash
export CLOUDFLARE_EMAIL=... CLOUDFLARE_API_KEY=... CF_ACCOUNT_ID=... CF_ZONE_ID=...
python3 infra/review-env/scripts/cf-tunnel.py \
  --host pair.example.com --origin-sni origin.example.com
# 按脚本输出的提示安装 cloudflared 服务
cloudflared service install "$(cat /root/.ppass-review-token)" && rm -f /root/.ppass-review-token
```

装 `cloudflared` 本身体积 19MB：**在本地下载 .deb 再 scp**（服务器直连 GitHub 只有 ~100KB/s）。

## 验收（部署后照着跑）

```bash
# 1) 不动凭据：必须 401
curl -sS -o /dev/null -w '%{http_code}\n' https://pair.example.com/
# 2) 带凭据：200，且能拿到二维码串
curl -sS -u review:<密码> https://pair.example.com/api/qr
# 3) 二维码图能生成
curl -sS -u review:<密码> -o /tmp/qr.png -w '%{http_code} %{size_download}\n' \
  "https://pair.example.com/api/qr.png?d=ppf%3A%2F%2Fpair%3Fnode%3Dabc%26t%3D1"
# 4) 境外可达性（本机在境内可能被策略拦，别用本地结果下结论）
#    check-host.net 或任意境外节点访问 https://pair.example.com/ → 401 即边缘链路通
```

手机侧：扫码 → 回页面点「允许」→ 手机开始备份 → 在页面上看到待确认列表清空。

### 语言

页面中英双语，**默认跟随浏览器语言**（`zh*` → 中文，其余 → English），右上角按钮手动切换
（记在 localStorage）。给审核员写地址时可以带 `?lang=en` 强制英文，例如：

```
https://pair.example.com/?lang=en
```

审核员多数在海外，`?lang=en` 建议直接写进 App Store Connect 的审核备注——少一步「他看不懂中文」的风险。

## 运维

- 日志：`journalctl -u ppass-review -u ppass-pairpage -u cloudflared`
- 备份到底成没成：看 `flow_delivery.state = completed` 与 `flow.round.finished`（见 `p-pass-file` skill 的四层验收法）
- 换码：页面上「换一张码」（每次 `pairing.start` 新令牌，10 分钟 TTL）
- **轮换身份/清库**（每轮审核结束后）：停 `ppass-review` → 删 `/var/lib/ppass-review` 内容 → 起服务（新 NodeId、空库）
- 审核结束关停：`systemctl stop ppass-review ppass-pairpage cloudflared`，或直接停机器

## 坑（都实测过）

| 现象 | 真相 / 处理 |
|---|---|
| 境内访问 443 直接被 RST、80 返回 `Server: Beaver` 403 | 未备案域名的拦截；只能用 Tunnel，换端口换证书都没用 |
| `SSL routines::ssl/tls alert handshake failure`（境外也这样） | 域名是**二级**子域，CF 免费版 Universal SSL 不覆盖 |
| `nginx: unknown directive "http2"` | Ubuntu 24.04 的 nginx 1.24，写 `listen 443 ssl http2;` |
| 每个请求 500，日志 `Permission denied` 开 htpasswd | 文件得能被 worker 读：`root:www-data` + 640 |
| 限流把正常用户挡住 | 走 Tunnel 后源站看到的对端是 CF 边缘 IP，必须 `set_real_ip_from` + `CF-Connecting-IP` |
| 在服务器上 curl 自己的公网域名超时 | 阿里云没有 hairpin NAT，本机验用 `--resolve …:127.0.0.1` |
| 后台跑脚本，ssh 一断全没了 | 用 `setsid ./x.sh > log 2>&1 < /dev/null &`，另起一条命令轮询日志 |
| 敲 `daemon --version` 把 ssh 挂死 | 参数没实现时会走「正常启动」分支，留下孤儿进程；版本看 `BUILD_INFO-*` |

## 本目录不含（刻意的）

- **一次性口令 / Turnstile**：Basic Auth 之外没有不可替代的收益，只增加输入负担
- **一键 reset 脚本**：多轮审核时再做；现阶段手工三步够用
- **任何账号、密码、令牌、私钥**：只存在于服务器与 App Store Connect

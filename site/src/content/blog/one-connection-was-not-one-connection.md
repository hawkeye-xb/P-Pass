---
title: 一条连接，为什么还是握手了五次
date: 2026-09-08
tags: [工程, 网络, 备份]
lang: zh
draft: true
---

> 草稿：尚未发布。它记录一次真实的连接复用排查，不把本机路径、设备标识、照片内容或配对信息写入公开文章。

连续传五张照片，照理说只该建一次底层连接。

这是我们一开始以为已经做完的事：Desktop 按 `(NodeId, ALPN)` 缓存一条活的 QUIC `Connection`；同一个对端、同一种协议的新文件只在那条连接上开新 stream。QUIC 本来就支持并发 stream，不需要传统连接池那套“借一条、还一条”的复杂度。

单测通过了。Android 的 Flow delivery 也不再临时 `DaemonClient()`，而是拿 App 进程已有的 Endpoint。看上去，一切都对。

然后真机传了五张图。日志告诉我们：底层还是握手了五次。

## 先分清三件不同的事

这类问题最容易被“连接”这个词混过去。实际至少有三层：

```text
Endpoint       = 一个设备在网络里的长期身份与路径知识
Connection     = 两个 Endpoint 之间的一条 QUIC 会话
Stream          = 一条 Connection 上的一次独立文件/请求
```

iroh 会替我们做 NAT 打洞、relay 兜底和路径升级；一个 Endpoint 也会积累到同一对端的路径知识。但它不会因为我们又调用一次 `connect()` 就自动把旧 `Connection` 还回来。

所以 Desktop 侧必须自己做 keyed cache：

```text
(peer NodeId, ALPN)
    └── live Connection
            ├── stream: 文件 1
            ├── stream: 文件 2
            └── stream: 文件 3
```

这一步没有错。问题在另一端。

## 第一次真机跑：缓存为什么总 miss

我们在已选相册放入五个明确标记的测试图，逐项检查手机 Flow 账本、Desktop 完成凭据和 daemon 调试日志。

结果表面上是好的：五项都进入 `CONFIRMED`，没有重试，每项都有回执。

但日志里五次 `ppf/blobs/1` 连接指向五个不同的 provider NodeId。Desktop 的 cache key 是 `(NodeId, ALPN)`；NodeId 每次都变，cache 当然只能 miss。

这不是 cache 算错了，而是测试暴露了一个被前一轮改动遮住的事实：**控制通道复用了 App 的 Endpoint，不等于真正搬运照片的 blobs provider 也复用了 Endpoint。**

控制面和数据面可以是不同身份，这是协议上允许也常见的形态。控制面负责授权一份不可变、带 hash 的 ticket；数据面 ticket 指向真正提供字节的 Endpoint。不能因为两者都在“同一台手机上”就想当然地把它们当成一个连接。

## 根因不在一处，而在两次“为安全而重建”

原生 blobs provider 的旧实现每次注册一张照片都会：

1. 新建私有 store；
2. 新建 iroh Endpoint；
3. 启动一个新的 blobs router；
4. 在下一张照片开始前关闭/撤销前一个 provider。

Flow bridge 也会在下一个严格队头开始前，对上一个 native provider 调 `stopActiveFetch` 和 `revoke`。

这些动作在“每张图一条连接”的旧世界里很直观：不要让旧文件继续被服务。但它们同时把任何可复用的 Endpoint、Connection 和路径知识都销毁了。

严格消费者的业务语义并不要求这么做。它要求的是：同一时刻只能有一个活跃 lease；暂停或取消时，那一个 active fetch 必须停止；旧照片不能在没有当前 lease 的情况下继续被拿走。

它**不要求**在一张照片成功结束、下一张照片正常开始时把整个网络身份砍掉。

## 修复：把生命周期对齐到真正的边界

修复不是把暂停语义变松，也不是给业务层造一个“池”。而是把资源生命周期挪回该在的位置：

```text
Provider 生命周期
  └── 一个 Endpoint
  └── 一个 private blob store
  └── 一个可切换的 blobs handler

严格队头正常推进
  └── 注册下一张 → 保留 Endpoint / Connection

Pause / Cancel / revoke
  └── 停止 active fetch → 关闭当前数据面服务
  └── 下次恢复才创建新的 active handler
```

也就是说：**正常相邻项是新 stream，不是新 Endpoint；用户明确中断才是中断点。**

这保留了 ARCH-03 的严格消费者边界。消费者仍只决定“哪一张能开始、何时取消”；传输层只决定“这条仍活着的连接能不能承载新的 stream”。两者没有互相偷权限。

## 这次怎样证明不是“碰巧绿了”

我们把证明拆成了三段。

### 1. 本地反证

新的 transport integration test 要求：

- 同一个 `(peer, ALPN)` 连续开两次 stream，只出现一条 inbound connection；
- ctrl 与 blobs 两个 ALPN 仍是两条独立连接；
- Android provider 连续注册两张不同内容，ticket 的 provider identity 必须相同；
- receiver 通过 `fetch_from` 连续拿两张，第二张仍走同一 provider identity。

把 cache 路径换回“每次 connect”，对应断言会失败；这不是只检查“传输最终成功”。

### 2. 协议语义审计

连接复用把“一请求一连接”改成“多 stream 共用一连接”，所以还检查了 server 的接收循环。拒绝、坏请求、取消或一个 stream 的正常结束，都不能让后续 stream 绕过授权，也不能让接收方悄悄停止接受新 stream。

这类回归不会出现在一张照片的一次 happy path 里，却会在 revoke → re-pair、重试或长连接时出现。

### 3. 真机证据

修复后的三星实测里，五个新的测试文件全部 `CONFIRMED`、零重试、各有完成凭据。daemon debug 日志只出现一次 `ppf/blobs/1` connection/hole-punch；随后五个 `iroh-blobs` get 请求都在那条连接上发生。

第一轮真机并没有“顺利通过”，它证明了我们漏了一层。第二轮才证明修复真的打到了数据面。

## 仍然没完成的事

这不是“网络问题已经永远解决”。当前只证明了连续成功项的连接复用。

Pause、Cancel 和失败后 Retry 的真机回归仍是独立验收：它们必须停止当前 stream，保留或处理 partial，随后按既有 Flow 语义恢复；又不能为了复用连接把用户的显式停止变成静默继续。

这也是这次排查留下的最重要记录：

> 性能优化只有在资源生命周期和业务生命周期对齐时才是真的优化。否则你只是把“新建连接”藏到另一层，直到真机日志把它重新叫出来。

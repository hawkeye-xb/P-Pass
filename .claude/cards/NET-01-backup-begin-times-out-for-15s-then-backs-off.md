# NET-01 半小时内三次传输层失败——`backup.begin` 卡满 15 秒才超时　级别 L2

> 🔴 状态：待调查（先定性，再决定修不修）
> 级别：**L2** · 阻塞：无

## 现象

2026-08-26 真机回归（0.4.0-test.8）半小时内三次：

```
17:04:33  DaemonUnreachableException: backup.begin: no response from the computer within 15000ms
17:16:48  IrohError { kind: Stream, message: "ConnectionLost(TimedOut)" }
17:23:40  DaemonUnreachableException: backup.begin: no response from the computer within 15000ms
```

验收人反馈的回归步骤 #18 大概率就是这个：

> 「重新打开 app，设置里面有提示，并且同步开始计算图片，**计算后等待较长时间
> 才发起重传**。」

**不是计算慢**——是 `backup.begin` 把 15 秒超时耗满，然后按 `MOB-02 §五` 的
30 秒指数退避重排。用户看到的就是「算完了，然后干等」。

## 要查清的（按顺序）

1. 这三次失败时 daemon 侧发生了什么？两端时间线对齐（daemon 日志在
   `~/Pictures/P-Pass 家庭照片库/` 的 `.log`/`.err`）。
2. `ConnectionLost(TimedOut)` 是 iroh 的连接空闲超时，还是真的网络断了？
   17:16:48 那次是**传到一半**断的（`sending 54/198` 之后），与另两次
   （`backup.begin` 阶段就打不通）可能不是同一个病。
3. 15000ms 这个超时值是否过长？握手阶段打不通，等 15 秒对用户是纯损失；
   但传输中的流不该被短超时砍断——两者可能需要不同的超时。

## 与已知项的关系

- 这三次都发生在**已授权白名单之后**，所以不是 `DOG-03` 的冻结问题。
- `UX-14` 修的是「失败被显示成被暂停」这个**呈现**缺陷；本卡查的是失败
  本身为什么发生。两张卡不重叠。

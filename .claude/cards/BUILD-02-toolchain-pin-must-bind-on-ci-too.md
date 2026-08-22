# BUILD-02 工具链钉在本地了，但 CI 侧不一定生效

> ⬜ 状态：未开工
> 级别：L2 · 阻塞：无（未开工，无阻塞可做）

## 问题

`rust-toolchain.toml` 钉住之后，**本地**确定是 1.98.0。但 CI 用的是：

```yaml
- uses: dtolnay/rust-toolchain@4cda84d5... # stable
  with:
    components: rustfmt, clippy
```

⚠️ **这个 action 是否导出 `RUSTUP_TOOLCHAIN`，不确定。** 如果导出了，
它会**盖掉** `rust-toolchain.toml`——CI 继续浮在最新 stable 上，本地钉在
1.98.0，漂移方向反过来但病还在（本地绿 → CI 红，一模一样的复发）。

不确定就不许当成已解决。要么核实，要么写成不依赖 action 语义的形式。

开卡原因：`BUILD-01` 的同一个病在 Rust 侧刚咬了一次（CI 红），本地已修，
**CI 侧能不能钉住需要验证**。

## 期望行为

CI 侧实际使用的 Rust 版本由 `rust-toolchain.toml` 唯一决定；凡是跑 cargo 的
workflow 都钉住，一个不漏。

## 验收标准

- [ ] CI 日志里 `rustc --version` 打出的版本 == `rust-toolchain.toml` 里的版本
- [ ] 反证：把 toml 改成一个更老的版本 → CI 日志里的版本必须跟着变（证明真的是 toml 在管，不是 action 在管）
- [ ] 五个 workflow 一个不漏（**"还有几个同形的"**——这次别只修 ci-rust）

## 范围

- 只准动：用 Rust 的 workflow——`ci-rust.yml` / `ci-desktop.yml` / `e2e.yml` / `release.yml` / `artifacts.yml`（**凡是跑 cargo 的都要**，漏一个那一条就还在浮）
- 不准动：`rust-toolchain.toml` 本身（已钉 1.98.0）；不在 workflow 里写死 `toolchain: 1.98.0`——版本号只许出现在 `rust-toolchain.toml` 一处，把同一个数抄两遍是制造下一次漂移，不是修它

## 阻塞与依赖

无。未开工，无阻塞可做。

---

## 备注

### 已经发生的事故（2026-08-21）

`just ci` 本地全绿，push 之后 CI 上 clippy 直接红：

```
error: using `chunks_exact` with a constant chunk size
  --> crates/transport/src/lib.rs:75:40
  = note: `-D clippy::chunks-exact-to-as-chunks` implied by `-D warnings`
  ...rust-1.98.0/index.html#chunks_exact_to_as_chunks
```

本地 stable = **1.91.0**（2025-10-28），CI 的 stable = **1.98.0** —— 差 7 个
小版本。这条 lint 在本地 clippy 里**根本不存在**，扫不出来。

全仓 **7 处** `chunks_exact(2)` 全中，CI 只报了第一个（`transport` 先炸就
`waiting for other jobs to finish`）。**只修 CI 报的那一处，必然换来第二次红。**

已修：7 处全改 `as_chunks::<2>()`；`rust-toolchain.toml` 从
`channel = "stable"` 钉成 `channel = "1.98.0"`；本地 rustup 升到 1.98.0，
用 1.98 的 clippy 复扫 `-D warnings` 全绿。

### 改法（倾向）

每个用 Rust 的 workflow 里，装完 toolchain 后加一步，让 `rust-toolchain.toml`
成为**唯一真相**：

```yaml
- name: 钉住工具链（rust-toolchain.toml 是唯一真相）
  run: |
    PINNED=$(grep -oE '^channel = "[^"]+"' rust-toolchain.toml | cut -d'"' -f2)
    rustup toolchain install "$PINNED" --component rustfmt --component clippy --profile minimal
    echo "RUSTUP_TOOLCHAIN=$PINNED" >> "$GITHUB_ENV"
    rustc --version    # 让日志里能一眼看到实际用的版本
```

解析逻辑已在本地验过（`[1.98.0]`）。

### 和 BUILD-01 是同一个病

| | 本地 | CI | 症状 |
|---|---|---|---|
| Rust | 跟着 rustup 的 stable 漂（曾停在 1.91） | 浮在最新 stable（1.98） | 本地绿 CI 红 ← **已发生** |
| JDK | 跟着 `brew --prefix openjdk` 漂（25） | 钉 `java-version: "17"` | 本地 release 构建炸（`BUILD-01`） |

**两个方向都出过事：本地落后 → CI 红；本地超前 → 本地红。** 结论一样：
**工具链版本必须有唯一真相，且两侧都从它取。**

### 升级流程（钉住之后的正确姿势）

工具链升级从"某天 CI 突然红"变成一次**显式提交**：

1. 改 `rust-toolchain.toml` 一行
2. `rustup update && just ci`
3. 修新版本顶出来的 lint
4. 一次提交，标题写明升到哪个版本

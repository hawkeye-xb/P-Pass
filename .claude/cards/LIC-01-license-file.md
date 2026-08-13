# LIC-01 补 LICENSE 文件　级别 L0

Cargo.toml 声明 license = "AGPL-3.0"，但仓库根**没有 LICENSE 文件**——
法律上无 LICENSE 全文 = 默认保留所有权利，开源身份不成立。

修法：仓库根加 AGPL-3.0 完整文本（GNU 官方原文，一字不改）；README
许可证小节一句话（en+zh）说明「客户端与全部代码 AGPL-3.0；官方托管
服务的运营配置不在本仓」。不加任何附加条款。

验收：LICENSE 与 GNU 官方文本逐字节一致（sha256 对照）；GitHub 仓库
页正确识别出 AGPL-3.0 徽章。收尾照旧 [skip ci]。

---

## 验收记录（2026-08-13，队列巡检发现早已完成）

本卡实际已在 `a2a1444`（chore(lic-01): 补 AGPL-3.0 LICENSE 全文 +
site/desktop package.json license 字段 + README License 段）完成，
只是当时没把卡移 done/，队列里挂了个已完成的空卡。核实：仓库根
`LICENSE` 存在（34582 字节，开头是标准 AGPL-3.0 v3 header），来自
该 commit。卡移 done/ 收尾，不重做。

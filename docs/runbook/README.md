# docs/runbook

When things break, look here (handbook §9): smartscreen / iroh-issue /
relay-down / key-compromise / release-checklist / lost-or-corrupted-index /
android-fgs-quota (reproduce the Android 15 dataSync FGS time limit in minutes) /
upgrade-compat (what an old → new upgrade promises; REL-06 matrix criteria, draft) /
full-regression-sop (the pre-release full regression run, agent-executable on any Mac or Windows desktop + Android pair; Windows specifics in its §9) /
update-signing-keys (test / stable update-signing keys: setup, rotation, compromise; the key-compromise procedure lives in its "suspected leak" section).

---

遇事翻这里（手册 §9）：smartscreen / iroh-issue / relay-down /
key-compromise / release-checklist / lost-or-corrupted-index（索引丢失
/损坏排查，低优先级挂账，`docs/runbook/lost-or-corrupted-index.md`）/
android-fgs-quota（几分钟内复现 Android 15 dataSync 前台服务配额耗尽，
`docs/runbook/android-fgs-quota.md`）/
upgrade-compat（「老版本 → 新版本」兼容承诺，REL-06 升级验证矩阵的判据，
草案待拍板，`docs/runbook/upgrade-compat.md`）/
full-regression-sop（正式发版前的全量回归，任意一套 Mac 或 Windows 桌面 + Android 上 agent 可照做，Windows 差异见其 §9，
`docs/runbook/full-regression-sop.md`）/
update-signing-keys（更新签名密钥：test 与正式各一把的配置、轮换、泄露处置——key-compromise 的处置流程就在它的「疑似泄露」一节，
`docs/runbook/update-signing-keys.md`）。

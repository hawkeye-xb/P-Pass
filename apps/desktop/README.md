# apps/desktop

Tauri tray shell (T-041/T-042): status, settings, pairing QR, device management.
Shell = UI + hosting (ADR-012): business rules live in the daemon (local IPC and its `config` / `diag` subcommands); the shell renders and hosts the daemon process. Rules: `docs/desktop/business-rules.zh-CN.md`.

---

Tauri 托盘壳（T-041/T-042）：状态、设置、配对 QR、设备管理。
壳 = UI + 托管（ADR-012）：业务规则在 daemon（本地 IPC 与 `config` / `diag` 子命令），壳只负责呈现与托管 daemon 进程。规则见 `docs/desktop/business-rules.zh-CN.md`。

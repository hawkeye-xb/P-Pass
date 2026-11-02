#!/usr/bin/env python3
"""门禁：尊重用户停掉的服务（AGENTS.md 产品硬规矩「尊重用户停掉的服务」）。

扫描「自启 / 拉起 / 周期调度」类调用点，每个含这类调用的文件都必须在
tools/autostart-registry.txt 里登记：
  autostart|<文件>|<保护>|<说明>
  <保护> 二选一：
    guard:<符号>   调用前会先检查「用户停过」的判断函数 / 类型名（符号必须仍存在于仓库）
    test:<符号>    由 contract 测试覆盖（测试名必须仍存在）
  <说明> 写清用户停过时这里为什么不会拉起来（或为什么这一处本身就是用户主动触发）。
未登记的新调用点 → 红；登记的符号被改名删除 → 红；登记的文件不再含调用 → 红。

只能证明「有人登记过、符号还在」，证明不了守卫语义——语义靠登记时的 review 和 contract 测试。
扫描目标：Android startForegroundService / WorkManager 入队与周期任务 / BOOT_COMPLETED / AlarmManager；
macOS launchctl bootstrap|kickstart；Windows StartService / schtasks /Create|/Run；iOS BGTaskScheduler.submit；
桌面 install_autostart / kickstart_shell_agent。自测：tools/test-check-autostart.sh。
"""
from __future__ import annotations

import re
from pathlib import Path

from fitness_lib import compare, die, load_registry, parse_args, read_product, symbol_exists, tracked_files

PATTERNS = re.compile(
    r"startForegroundService\(|\bstartService\(|PeriodicWorkRequest|enqueueUnique(Periodic)?Work\(|"
    r"\bworkManager\.enqueue|\.enqueue\(\s*\w*[Rr]equest|AlarmManager|setRepeating|setExactAndAllowWhileIdle|"
    r"android\.intent\.action\.BOOT_COMPLETED|Intent\.ACTION_BOOT_COMPLETED|"
    r"\[\s*\"(bootstrap|kickstart)\"|\bStartServiceW\(|schtasks[^\n]*/(Create|Run)\b|"
    r"BGTaskScheduler\.shared\.submit|SMAppService|\binstall_autostart\(|\bkickstart_shell_agent\("
)
EXT = (".kt", ".java", ".rs", ".swift", ".nsh", ".xml", ".plist")


def main() -> None:
    args = parse_args("尊重用户停服务门禁")
    root = Path(args.root)
    reg = load_registry(Path(args.registry or root / "tools/autostart-registry.txt"), {"autostart": 4})
    found: dict[tuple[str, str], str] = {}
    for rel in tracked_files(root):
        if not rel.endswith(EXT):
            continue
        for n, line in read_product(root, rel):
            if PATTERNS.search(line):
                found.setdefault(("autostart", rel), f"{rel}:{n}")
                break
    errs = compare(found, reg, "自启 / 拉起调用点",
                   "在 tools/autostart-registry.txt 登记 `autostart|文件|guard:<判断函数>或test:<测试名>|说明`；"
                   "写不出「会先检查用户停过」的函数或测试，就说明这处该改，而不是该登记")
    for (kind, key), rest in sorted(reg.items()):
        if (kind, key) not in found:
            continue
        prot = rest[0]
        m = re.fullmatch(r"(guard|test):([A-Za-z_][\w]*)", prot)
        if not m:
            errs.append(f"✗ {key}：保护字段必须是 guard:<符号> 或 test:<符号>，现为 `{prot}`")
        elif not symbol_exists(root, m.group(2)):
            errs.append(f"✗ {key}：登记的{m.group(1)}符号 `{m.group(2)}` 在仓库里找不到（改名或删除了？）\n    → 更新登记，且确认新的守卫仍先检查用户停过")
    if errs:
        die(errs)
    print(f"ok: 自启 / 拉起调用点与 tools/autostart-registry.txt 一致（{len(reg)} 处，守卫符号均存在）")


if __name__ == "__main__":
    main()

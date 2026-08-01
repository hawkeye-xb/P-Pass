# H-09 Windows 真机冒烟 — 执行说明书（给 Win 测试机器代理）

> 目标机器：Windows 测试机（x64）。本机 agent 按此文件执行冒烟并把结果
> 回报到 Discord。所有步骤的输出都应当**原文回贴**（日志行、退出码），
> 不要只贴结论。

## 0. 前置检查（30 秒）

1. `git --version`、`powershell` 可用（Win10/11 自带）
2. 网络可达 github.com
3. 如果杀软/Defender 拦截 daemon.exe —— **按 docs/troubleshooting/blocked-by-av.md
   三步验证**（SHA-256 对照 bin-win-x64 的 SHA256SUMS），确认一致后放行，
   并在回报里注明"被拦截过、已放行"

## 1. 拉取二进制（纯 git 分发，免认证）

```powershell
cd $env:TEMP
git clone --depth 1 --branch bin-win-x64 https://github.com/hawkeye-xb/P-Pass.git ppf-win-bin
cd ppf-win-bin
# 应有: daemon.exe  testclient.exe  win-smoke.ps1  SHA256SUMS  BUILD_INFO
Get-Content SHA256SUMS   # 记录哈希备用
```

## 2. 校验哈希（可选但推荐）

```powershell
Get-FileHash daemon.exe -Algorithm SHA256
Get-FileHash testclient.exe -Algorithm SHA256
# 与 SHA256SUMS 一致才继续
```

## 3. 跑冒烟

```powershell
powershell -ExecutionPolicy Bypass -File win-smoke.ps1
```

期望终态：`WIN SMOKE: ALL GREEN`（工作目录默认 `%TEMP%\ppf-win-dogfood`）。

## 4. 回报模板（贴到 Discord）

```
[H-09 冒烟结果] <PASS/FAIL>
- 机器: <Windows 版本 + 架构>
- 步骤: 0 前置 / 1 拉取 / 2 哈希 / 3 冒烟
- 冒烟输出: <全文或关键行>
- IPC socket 路径探测结果: <脚本打印的那行，Win 上 interprocess 落点待实证>
- 异常/疑问: <如有>
```

## 5. 已知待实证项（脚本会打印，务必回报）

| 项 | 说明 |
|---|---|
| IPC socket 路径 | interprocess GenericNamespaced 在 Windows 的落点未知，脚本探测 6 个候选路径，打印第一个连通的 |
| 中文编码 | testclient 的"配对成功"在 GBK 控制台可能乱码——配对以退出码为准（脚本已如此处理） |
| Defender 拦截 | 未签名 exe 首次运行可能被拦——按 blocked-by-av 处理并注明 |
| daemon 控制台行为 | 无窗口启动（脚本用 Hidden），日志在 `%TEMP%\ppf-win-dogfood\daemon.log` |

## 6. 如果 FAIL —— 把这三样东西原文回报

1. `%TEMP%\ppf-win-dogfood\daemon.log` + `daemon.err`（如存在）末尾 30 行
2. 失败步骤的完整输出 + 退出码
3. 你的 Windows 版本号（`winver` 或 `[System.Environment]::OSVersion`）

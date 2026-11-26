# P-Pass justfile — single-person project task runner
# Run `just` for a list of available commands.
# 按领域拆到 tools/just/*.just；这里只保留全局设置、默认列表与模块 import。

# QA-08：Windows 上 just 默认去找 POSIX `sh`，而 Git for Windows 只把 Git 的
# cmd 目录放进 PATH —— sh.exe / bash.exe 在它的 bin 目录里，默认不在 PATH 上。
# 于是在 PowerShell 里任何一条配方都以 "could not find the shell sh" 失败，
# 而那句话指向「shell 找不到」，第一反应会是仓库坏了。
#
# 改用 bash：本仓的配方本来就是 POSIX 写的，而且已有配方直接调 bash
# （cleanup-local），所以「要求 bash 可用」是既成事实、不是新约束。只要
# bash 在 PATH 上，PowerShell 里也能直接跑 just。bash 不在 PATH 时仍会失败，
# 但 tools/windows/env-check.ps1 会明确报出来并给出修法（见 #179）。
#
# 只影响 Windows：其余平台仍用 just 默认的 `sh -cu`。
set windows-shell := ["bash", "-cu"]

# #1375 共享编译缓存：主副本与所有卡目录共用一份 CARGO_TARGET_DIR / Xcode DerivedData。
# 变量在主副本旁边的 .env.ppass-dev（just start 自动建，just 从当前目录往上找到它）；
# 没有这个文件（CI、新机器）时什么都不设，行为不变。环境里已设的变量优先。见 tools/e3/lib/dev-cache.sh。
set dotenv-filename := ".env.ppass-dev"
set dotenv-load

default:
  @just --list

import 'tools/just/workspace.just'
import 'tools/just/rust.just'
import 'tools/just/checks.just'
import 'tools/just/desktop.just'
import 'tools/just/android.just'
import 'tools/just/ios.just'
import 'tools/just/e3.just'
import 'tools/just/flow.just'

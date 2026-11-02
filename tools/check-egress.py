#!/usr/bin/env python3
"""门禁：无遥测 / 不新增外联（AGENTS.md 红线 2；决策记录 docs/product/2026-10-13-telemetry-removal.md）。

静态扫描各端产品源码里的网络出口，与 tools/egress-allowlist.txt 比对：
  site|<文件>|<用途>   该文件里有网络客户端 / 套接字 / 更新器调用（Rust reqwest|ureq|hyper|iroh Endpoint…、
                       Kotlin HttpURLConnection|URL(…、Swift URLSession…、桌面 fetch|axios|更新器插件…）
  host|<主机名>|<用途> 产品源码 / 配置里出现的外部主机名字面量（example/invalid/localhost 等占位除外）
  dep |<依赖名>|<用途> 清单里声明的网络类依赖（HTTP 客户端、更新器插件）
另有一份**硬禁令**：分析 / 崩溃上报类 SDK（sentry、firebase、crashlytics、mixpanel…）出现在任何依赖
清单里一律红，没有登记入口——要改这条须产品负责人拍板（红线 2）。

新增出口必须登记，登记要在 PR 里说明为什么。自测：tools/test-check-egress.sh。
"""
from __future__ import annotations

import re
from pathlib import Path

from fitness_lib import compare, die, load_registry, parse_args, read_product, tracked_files

RS = re.compile(
    r"\b(reqwest|ureq|hyper_util|isahc|attohttpc|tauri_plugin_updater|TcpStream::connect|UdpSocket::bind|"
    r"Endpoint::builder|RelayMode)\b|hyper::client"
)
KT = re.compile(
    r"HttpURLConnection|HttpsURLConnection|openConnection\(|OkHttp|java\.net\.(URL|Socket)\b|"
    r"DownloadManager|\bURL\(|\bSocket\("
)
SWIFT = re.compile(r"URLSession|URLRequest|NWConnection|WKWebView|CFSocket")
JS = re.compile(
    r"\bfetch\(|\baxios\b|XMLHttpRequest|new WebSocket|\bEventSource\b|sendBeacon|@tauri-apps/plugin-(updater|http)"
)
CONF = re.compile(r'"endpoints"|android\.permission\.INTERNET|NSAppTransportSecurity|NSAllowsArbitraryLoads')

HOST = re.compile(r"\b(?:https?|wss?)://([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})")
HOST_IGNORE = re.compile(
    r"(^|\.)(example|invalid|localhost|test|local)$|(^|\.)example\.(com|org|net)$|^(www\.)?w3\.org$|"
    r"(^|\.)apple\.com$|^schemas\.(android|microsoft)\.com$|^schema\.tauri\.app$|^json-schema\.org$"
)

HTTP_DEPS = (
    "reqwest", "ureq", "hyper", "hyper-util", "isahc", "attohttpc", "surf", "curl",
    "tauri-plugin-http", "tauri-plugin-updater", "@tauri-apps/plugin-http", "@tauri-apps/plugin-updater",
    "okhttp", "retrofit", "ktor-client", "volley", "axios", "alamofire",
)
BANNED_DEPS = (
    "sentry", "firebase", "crashlytics", "mixpanel", "amplitude", "posthog", "segment", "umeng", "bugly",
    "appcenter", "datadog", "bugsnag", "google-analytics", "gtag", "matomo", "opentelemetry", "telemetry-deck",
)
# 只在源码 / 配置里扫主机名；锁文件、lint 基线、组件生成配置里的链接不是产品出口。
HOST_EXT = (".rs", ".kt", ".java", ".swift", ".js", ".ts", ".svelte", ".html", ".toml", ".plist")
MANIFEST = re.compile(r"(^|/)(Cargo\.toml|package\.json|build\.gradle(\.kts)?|libs\.versions\.toml|Package\.swift|Podfile)$")


def lang_re(rel: str):
    if rel.endswith(".rs"):
        return RS
    if rel.endswith((".kt", ".java")):
        return KT
    if rel.endswith(".swift"):
        return SWIFT
    if rel.endswith((".js", ".ts", ".svelte", ".tsx", ".html")):
        return JS
    if rel.endswith(("tauri.conf.json", "AndroidManifest.xml", "Info.plist")):
        return CONF
    return None


def dep_re(name: str):
    return re.compile(r"(?<![\w-])" + re.escape(name) + r"(?![\w-])", re.I)


def main() -> None:
    args = parse_args("无遥测 / 不新增外联门禁")
    root = Path(args.root)
    reg = load_registry(Path(args.registry or root / "tools/egress-allowlist.txt"), {"site": 3, "host": 3, "dep": 3})
    found: dict[tuple[str, str], str] = {}
    banned: list[str] = []
    for rel in tracked_files(root):
        lines = read_product(root, rel)
        rx = lang_re(rel)
        for n, line in lines:
            if rx and rx.search(line):
                found.setdefault(("site", rel), f"{rel}:{n}")
            if rel.endswith(HOST_EXT) or rel.endswith("tauri.conf.json"):
                for m in HOST.finditer(line):
                    h = m.group(1).lower().rstrip(".")
                    if not HOST_IGNORE.search(h):
                        found.setdefault(("host", h), f"{rel}:{n}")
            if MANIFEST.search(rel):
                for d in HTTP_DEPS:
                    if dep_re(d).search(line):
                        found.setdefault(("dep", d), f"{rel}:{n}")
                for d in BANNED_DEPS:
                    if dep_re(d).search(line):
                        banned.append(f"✗ 禁用的遥测 / 上报类依赖 `{d}`：{rel}:{n}\n    → 红线 2：不做任何遥测。没有登记入口，要改须产品负责人拍板")
    errs = banned + compare(found, reg, "网络出口", "加进 tools/egress-allowlist.txt（`种类|键|用途`），并在 PR 里说明为什么需要这个出口")
    if errs:
        die(errs)
    print(f"ok: 网络出口与 tools/egress-allowlist.txt 一致（{len(reg)} 条），无遥测类依赖")


if __name__ == "__main__":
    main()

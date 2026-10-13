//! 本地运行统计（#949 TEL-06：遥测上报已下线）。
//!
//! **不联网，仅写本地日志。** 本模块没有任何网络代码：每个事件都是一行
//! `tracing::info!`（target = [`TARGET`]），和 daemon 其余日志一起落进
//! 同一个日志 sink（`main.rs` 里由 `DedupGuard` 托管的那份，桌面端
//! 「导出日志」导出的就是它）。是否把日志交给我们，由用户自己决定。
//! 下线决策与历史：`docs/product/2026-10-13-telemetry-removal.md`。
//!
//! 事件字段沿用 OBS-02 裁决过的字典（`conn` / `flow_item` / `first_byte`
//! / `daemon_alive`），只保留对排查有用的固定词汇与数字，不带路径、文件名
//! 或原始错误文本。原先的 `anon_id` / `ts` / `ver` 公共字段不再需要——
//! 日志行自带时间戳，版本号由 `daemon_alive` 的 `ver` 字段记录。
//!
//! 原来的第五类 `error` 事件没有搬过来：Flow 交付的每个失败返回点在
//! `router.rs` 已有带完整原因的 `warn!`（offer/fetch/cancel 与
//! cancel_tuple），后台拉取失败在 `flow_delivery.rs` 的
//! `spawn_fetch_task` / `emit_flow_failed` 也各有日志行（含细分码
//! `detail=`）。再写一条 `error` 统计行只是重复。

/// 统计事件的 tracing target。过滤 / grep 日志时用它，例如
/// `RUST_LOG=ppf::stats=info`。
pub const TARGET: &str = "ppf::stats";

/// 统计事件字典（OBS-02 裁决的字段，去掉了只为上报服务的公共字段）。
#[derive(Debug, Clone)]
pub enum Event {
    Conn {
        path: &'static str, // direct | relay | offline | unknown (ConnectionStatus::as_str())
        ms: u64,
        fail_stage: Option<&'static str>,
    },
    FlowItem {
        bytes: u64,
        dur_s: u64,
        resumed: bool,
    },
    FirstByte {
        ms: u64,
        kind: &'static str, // thumb | blob
    },
    DaemonAlive {
        uptime_h: u64,
        os: String,
        ver: String,
    },
}

/// 把一个事件写成一行本地日志（info 级，target = [`TARGET`]）。
/// 同步、无队列、无网络：调用即落进 daemon 日志 sink。
pub fn record(event: Event) {
    match event {
        Event::Conn {
            path,
            ms,
            fail_stage,
        } => tracing::info!(
            target: TARGET,
            event = "conn",
            path,
            ms,
            fail_stage = fail_stage.unwrap_or("none"),
            "stats"
        ),
        Event::FlowItem {
            bytes,
            dur_s,
            resumed,
        } => tracing::info!(
            target: TARGET,
            event = "flow_item",
            bytes,
            dur_s,
            resumed,
            "stats"
        ),
        Event::FirstByte { ms, kind } => {
            tracing::info!(target: TARGET, event = "first_byte", ms, kind, "stats")
        }
        Event::DaemonAlive { uptime_h, os, ver } => tracing::info!(
            target: TARGET,
            event = "daemon_alive",
            uptime_h,
            os = %os,
            ver = %ver,
            "stats"
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::{Arc, Mutex};

    /// 把 fmt 层的输出收进内存，供断言读取。
    #[derive(Clone, Default)]
    struct Capture(Arc<Mutex<Vec<u8>>>);

    impl Write for Capture {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0
                .lock()
                .expect("capture buffer")
                .extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Capture {
        type Writer = Capture;
        fn make_writer(&'a self) -> Self::Writer {
            self.clone()
        }
    }

    /// 用与 `main.rs` 完全相同的默认过滤串搭 subscriber，证明事件能穿过
    /// **生产过滤器**落进日志 sink，而不只是"打了一行日志"。
    fn capture_with_production_filter(f: impl FnOnce()) -> String {
        let capture = Capture::default();
        let subscriber = tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::new(format!(
                "info,{}",
                transport::QUIET_LOG_DIRECTIVES
            )))
            .with_ansi(false)
            .with_writer(capture.clone())
            .finish();
        tracing::subscriber::with_default(subscriber, f);
        let bytes = capture.0.lock().expect("capture buffer").clone();
        String::from_utf8(bytes).expect("utf8 log output")
    }

    #[test]
    fn every_event_lands_in_the_daemon_log_under_the_stats_target() {
        let out = capture_with_production_filter(|| {
            record(Event::Conn {
                path: "direct",
                ms: 120,
                fail_stage: None,
            });
            record(Event::FlowItem {
                bytes: 1024,
                dur_s: 5,
                resumed: false,
            });
            record(Event::FirstByte {
                ms: 80,
                kind: "thumb",
            });
            record(Event::DaemonAlive {
                uptime_h: 24,
                os: "macos".into(),
                ver: "0.1.0".into(),
            });
        });
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines.len(), 4, "每个事件恰好一行：{out}");
        for (line, name) in lines
            .iter()
            .zip(["conn", "flow_item", "first_byte", "daemon_alive"])
        {
            assert!(line.contains(" INFO "), "info 级：{line}");
            assert!(line.contains(TARGET), "target 必须是 {TARGET}：{line}");
            assert!(
                line.contains(&format!("event=\"{name}\"")),
                "缺事件名 {name}：{line}"
            );
        }
        assert!(lines[0].contains("path=\"direct\"") && lines[0].contains("ms=120"));
        assert!(lines[0].contains("fail_stage=\"none\""));
        assert!(lines[1].contains("bytes=1024") && lines[1].contains("resumed=false"));
        assert!(lines[2].contains("kind=\"thumb\""));
        assert!(lines[3].contains("uptime_h=24") && lines[3].contains("os=macos"));
    }
}

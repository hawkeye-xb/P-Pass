//! Daemon configuration (T-004).
//!
//! Three-layer precedence, lowest to highest:
//! 1. compiled-in defaults (official endpoints from `config/endpoints.default.toml`)
//! 2. user `config.toml`
//! 3. `PPF_*` environment variables
//!
//! 隔离方案 §2: official endpoints are public constants baked into the
//! binary; every one of them can be overridden by self-hosters.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::Context;
use serde::Deserialize;

/// Official endpoint defaults, embedded at compile time.
const ENDPOINTS_DEFAULT: &str = include_str!("../../../config/endpoints.default.toml");

/// Fully resolved daemon configuration.
#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    /// Library root. `None` = let the platform adapter pick the
    /// OS-conventional data dir (T-040).
    pub data_dir: Option<PathBuf>,
    /// UDP bind address, e.g. `0.0.0.0:41145`. `None` = OS-assigned port.
    /// Cloud/dogfood deployments pin this to the firewall-allowed port.
    pub bind_addr: Option<std::net::SocketAddr>,
    pub relay_urls: Vec<String>,
    pub rendezvous_url: String,
    pub telemetry: TelemetryConfig,
    pub log_level: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TelemetryConfig {
    pub enabled: bool,
    pub url: String,
}

/// Partial overlay as read from `config.toml` — every field optional.
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Overlay {
    data_dir: Option<PathBuf>,
    bind_addr: Option<std::net::SocketAddr>,
    relay_urls: Option<Vec<String>>,
    rendezvous_url: Option<String>,
    telemetry: Option<TelemetryOverlay>,
    log_level: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct TelemetryOverlay {
    enabled: Option<bool>,
    url: Option<String>,
}

impl Config {
    /// Compiled-in defaults (layer 1).
    pub fn default_config() -> anyhow::Result<Config> {
        let overlay: Overlay = toml::from_str(ENDPOINTS_DEFAULT)
            .context("built-in endpoints.default.toml is invalid")?;
        let telemetry = overlay.telemetry.unwrap_or_default();
        Ok(Config {
            data_dir: None,
            bind_addr: None,
            relay_urls: overlay.relay_urls.unwrap_or_default(),
            rendezvous_url: overlay.rendezvous_url.unwrap_or_default(),
            telemetry: TelemetryConfig {
                enabled: telemetry.enabled.unwrap_or(true),
                url: telemetry.url.unwrap_or_default(),
            },
            log_level: overlay.log_level.unwrap_or_else(|| "info".to_string()),
        })
    }

    /// Load with full precedence from an optional config file and the
    /// process environment.
    pub fn load(config_path: Option<&Path>) -> anyhow::Result<Config> {
        let file_toml = match config_path {
            Some(p) if p.exists() => Some(
                std::fs::read_to_string(p).with_context(|| format!("reading {}", p.display()))?,
            ),
            _ => None,
        };
        let env: HashMap<String, String> = std::env::vars().collect();
        Self::resolve(file_toml.as_deref(), &env)
    }

    /// Pure resolution — testable without touching process env or disk.
    pub fn resolve(
        config_toml: Option<&str>,
        env: &HashMap<String, String>,
    ) -> anyhow::Result<Config> {
        // Layer 1: defaults.
        let mut cfg = Self::default_config()?;

        // Layer 2: config.toml overlay.
        if let Some(raw) = config_toml {
            let overlay: Overlay = toml::from_str(raw).context("parsing config.toml")?;
            if let Some(v) = overlay.data_dir {
                cfg.data_dir = Some(v);
            }
            if let Some(v) = overlay.bind_addr {
                cfg.bind_addr = Some(v);
            }
            if let Some(v) = overlay.relay_urls {
                cfg.relay_urls = v;
            }
            if let Some(v) = overlay.rendezvous_url {
                cfg.rendezvous_url = v;
            }
            if let Some(t) = overlay.telemetry {
                if let Some(v) = t.enabled {
                    cfg.telemetry.enabled = v;
                }
                if let Some(v) = t.url {
                    cfg.telemetry.url = v;
                }
            }
            if let Some(v) = overlay.log_level {
                cfg.log_level = v;
            }
        }

        // Layer 3: PPF_* environment variables (highest precedence).
        if let Some(v) = env.get("PPF_DATA_DIR") {
            cfg.data_dir = Some(PathBuf::from(v));
        }
        if let Some(v) = env.get("PPF_BIND_ADDR") {
            cfg.bind_addr =
                Some(v.parse().map_err(|e| {
                    anyhow::anyhow!("PPF_BIND_ADDR 不是合法的 IP:端口（{v}）：{e}")
                })?);
        }
        if let Some(v) = env.get("PPF_RELAY_URLS") {
            cfg.relay_urls = v
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
        }
        if let Some(v) = env.get("PPF_RENDEZVOUS_URL") {
            cfg.rendezvous_url = v.clone();
        }
        if let Some(v) = env.get("PPF_TELEMETRY_ENABLED") {
            cfg.telemetry.enabled = parse_bool("PPF_TELEMETRY_ENABLED", v)?;
        }
        if let Some(v) = env.get("PPF_TELEMETRY_URL") {
            cfg.telemetry.url = v.clone();
        }
        if let Some(v) = env.get("PPF_LOG_LEVEL") {
            cfg.log_level = v.clone();
        }

        Ok(cfg)
    }
}

fn parse_bool(var: &str, raw: &str) -> anyhow::Result<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" | "on" => Ok(true),
        "false" | "0" | "no" | "off" => Ok(false),
        other => anyhow::bail!("{var} must be a boolean, got {other:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn layer1_defaults_have_official_endpoints() {
        let cfg = Config::resolve(None, &env(&[])).unwrap();
        // relay_urls 默认空（2026-07-31 用户裁决）：H-07 部署前官方 relay 域名
        // 不存在，会毒害路径协商（dogfood 实证）；H-07 上线后恢复三区域列表
        // （见 config/endpoints.default.toml 注释）。
        assert!(cfg.relay_urls.is_empty());
        assert!(cfg.rendezvous_url.contains("rendezvous"));
        assert!(cfg.telemetry.enabled);
        // T-061b-fix: the telemetry Worker only accepts POSTs on /ingest —
        // the compiled-in default URL must carry the suffix or a stock
        // daemon 404s every batch silently.
        assert!(
            cfg.telemetry.url.ends_with("/ingest"),
            "默认 telemetry url 必须带 /ingest，实际: {}",
            cfg.telemetry.url
        );
        assert_eq!(cfg.log_level, "info");
        assert_eq!(cfg.data_dir, None);
    }

    #[test]
    fn layer2_file_overrides_defaults_partially() {
        let file = r#"
            data_dir = "/tmp/lib"
            relay_urls = ["https://relay.self-host.example"]
            [telemetry]
            enabled = false
        "#;
        let cfg = Config::resolve(Some(file), &env(&[])).unwrap();
        assert_eq!(cfg.data_dir, Some(PathBuf::from("/tmp/lib")));
        assert_eq!(cfg.relay_urls, vec!["https://relay.self-host.example"]);
        assert!(!cfg.telemetry.enabled);
        // Untouched fields keep defaults.
        assert!(cfg.rendezvous_url.contains("p-pass.hawkeye-xb.com"));
        assert!(cfg.telemetry.url.contains("telemetry"));
        assert_eq!(cfg.log_level, "info");
    }

    #[test]
    fn layer3_env_overrides_file_and_defaults() {
        let file = r#"
            log_level = "debug"
            [telemetry]
            enabled = true
        "#;
        let e = env(&[
            ("PPF_BIND_ADDR", "0.0.0.0:41145"),
            ("PPF_TELEMETRY_ENABLED", "false"),
            ("PPF_LOG_LEVEL", "warn"),
            ("PPF_RELAY_URLS", "https://a.example, https://b.example"),
            ("PPF_DATA_DIR", "/env/dir"),
        ]);
        let cfg = Config::resolve(Some(file), &e).unwrap();
        assert!(
            !cfg.telemetry.enabled,
            "PPF_TELEMETRY_ENABLED=false 必须生效"
        );
        assert_eq!(cfg.log_level, "warn");
        assert_eq!(
            cfg.relay_urls,
            vec!["https://a.example", "https://b.example"]
        );
        assert_eq!(cfg.data_dir, Some(PathBuf::from("/env/dir")));
        assert_eq!(
            cfg.bind_addr,
            Some("0.0.0.0:41145".parse().unwrap()),
            "PPF_BIND_ADDR 必须生效"
        );
    }

    #[test]
    fn invalid_bool_env_is_an_error_not_a_default() {
        let e = env(&[("PPF_TELEMETRY_ENABLED", "maybe")]);
        let err = Config::resolve(None, &e).unwrap_err();
        assert!(err.to_string().contains("PPF_TELEMETRY_ENABLED"));
    }

    #[test]
    fn unknown_file_field_is_rejected() {
        let err = Config::resolve(Some("no_such_field = 1"), &env(&[])).unwrap_err();
        assert!(err.to_string().contains("parsing config.toml"));
    }
}

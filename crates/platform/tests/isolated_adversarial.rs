//! 隔离子进程的对抗实测（Windows）：在 `spawn_isolated` 拉起的子进程里尝试
//! 读 / 联网 / 建进程 / 超内存，必须全部失败；只有标准输入输出管道通。
//!
//! 子进程就是本测试二进制自己（环境变量分流），所以 `harness = false`。
//! 每条断言都配对照：同样的动作在父进程（无隔离）里必须成功——否则「子进程里失败」
//! 说明不了什么（可能是文件根本不存在、端口根本没开）。
//!
//! 前置：AppContainer 默认读不到测试二进制所在目录，本测试先用 `icacls` 给
//! `ALL APPLICATION PACKAGES`（`*S-1-15-2-1`）授读 + 执行；生产安装目录
//! （Program Files）默认已带这个权限。

#![allow(clippy::disallowed_methods)]

#[cfg(windows)]
fn main() {
    imp::main()
}

#[cfg(not(windows))]
fn main() {
    eprintln!("仅 Windows——跳过");
}

#[cfg(windows)]
mod imp {

    use std::collections::HashMap;
    use std::io::{Read, Write};
    use std::net::{SocketAddr, TcpListener, TcpStream};
    use std::time::Duration;

    use platform::isolated::{spawn_isolated, Isolation, Limits};

    const CHILD_ENV: &str = "PPF_ISO_PROBE_CHILD";

    pub fn main() {
        if std::env::var_os(CHILD_ENV).is_some() {
            child();
        } else {
            parent();
        }
    }

    fn verdict<T, E: std::fmt::Display>(r: Result<T, E>) -> String {
        match r {
            Ok(_) => "allowed".into(),
            Err(e) => format!("denied({e})").replace(['\n', '\r', '='], " "),
        }
    }

    /// 要探的动作；父子共用同一份，保证对照是同一个动作。
    fn probes() -> Vec<(&'static str, String)> {
        let env = |k: &str| std::env::var(k).unwrap_or_default();
        let secret = env("PPF_PROBE_SECRET");
        let userfile = env("PPF_PROBE_USERFILE");
        let port: u16 = env("PPF_PROBE_PORT").parse().unwrap_or(0);
        let mem = {
            let mut v: Vec<u8> = Vec::new();
            match v.try_reserve_exact(512 << 20) {
                Ok(()) => {
                    v.resize(512 << 20, 1);
                    Ok(())
                }
                Err(e) => Err(e.to_string()),
            }
        };
        vec![
            ("read_secret_dir_file", verdict(std::fs::read(secret))),
            ("read_user_file", verdict(std::fs::read(userfile))),
            (
                "write_windows_temp",
                verdict(std::fs::write(r"C:\Windows\Temp\ppf-iso-probe.txt", b"x")),
            ),
            (
                "connect_external",
                verdict(TcpStream::connect_timeout(
                    &SocketAddr::from(([1, 1, 1, 1], 443)),
                    Duration::from_secs(4),
                )),
            ),
            (
                "connect_loopback",
                verdict(TcpStream::connect_timeout(
                    &SocketAddr::from(([127, 0, 0, 1], port)),
                    Duration::from_secs(3),
                )),
            ),
            (
                "spawn_child_process",
                verdict(
                    std::process::Command::new(r"C:\Windows\System32\cmd.exe")
                        .args(["/c", "exit", "0"])
                        .status(),
                ),
            ),
            ("alloc_512mb", verdict(mem)),
        ]
    }

    fn child() {
        let mut input = Vec::new();
        let piped = std::io::stdin().read_to_end(&mut input);
        let mut out = String::new();
        for (k, v) in probes() {
            out.push_str(&format!("{k}={v}\n"));
        }
        out.push_str(&format!("pipe_bytes={}\n", piped.unwrap_or(0)));
        let mut so = std::io::stdout();
        let _ = so.write_all(out.as_bytes());
        let _ = so.flush();
    }

    fn parse(s: &str) -> HashMap<String, String> {
        s.lines()
            .filter_map(|l| l.split_once('='))
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    fn parent() {
        let exe = std::env::current_exe().unwrap();
        let dir = exe.parent().unwrap();
        // 给 AppContainer 开读 + 执行（test 目录与其 deps）。
        let ok = std::process::Command::new("icacls")
            .arg(dir)
            .args(["/grant", "*S-1-15-2-1:(OI)(CI)(RX)", "/T", "/C", "/Q"])
            .status()
            .unwrap()
            .success();
        assert!(ok, "icacls 授权失败");

        // 夹具：秘密文件放在只有当前用户可读的临时目录（继承 %TEMP% 的 ACL，
        // AppContainer 不在其中）；回环端口真的开着。
        let tmp = tempfile::tempdir().unwrap();
        let secret = tmp.path().join("secret.key");
        let userfile = tmp.path().join("user.txt");
        std::fs::write(&secret, b"k").unwrap();
        std::fs::write(&userfile, b"u").unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::env::set_var("PPF_PROBE_SECRET", &secret);
        std::env::set_var("PPF_PROBE_USERFILE", &userfile);
        std::env::set_var("PPF_PROBE_PORT", port.to_string());

        // 对照：同样的动作在无隔离的父进程里必须是 allowed（内存、建进程、联网除外：
        // 联网外网依赖 runner 出网，只要求回环；内存/建进程父进程也能做）。
        let control: HashMap<_, _> = probes()
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect();
        for k in [
            "read_secret_dir_file",
            "read_user_file",
            "connect_loopback",
            "spawn_child_process",
            "alloc_512mb",
        ] {
            assert_eq!(
                control[k], "allowed",
                "对照组 {k} 在无隔离时应成功: {}",
                control[k]
            );
        }

        // 实测：AppContainer + Job（内存上限 256MB，所以 512MB 必须失败）。
        std::env::set_var(CHILD_ENV, "1");
        let mut child = spawn_isolated(
            &exe,
            &Limits {
                memory_bytes: 256 << 20,
            },
        )
        .expect("拉起隔离子进程失败");
        std::env::remove_var(CHILD_ENV);
        assert_eq!(child.isolation(), Isolation::AppContainer);
        let killer = child.killer();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(60));
            killer.kill();
        });
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(&[7u8; 1000]).unwrap();
        drop(stdin);
        let mut out = String::new();
        child
            .stdout
            .take()
            .unwrap()
            .read_to_string(&mut out)
            .unwrap();
        let _ = child.wait();
        let got = parse(&out);
        println!("{out}");

        for k in [
            "read_secret_dir_file",
            "read_user_file",
            "write_windows_temp",
            "connect_external",
            "connect_loopback",
            "spawn_child_process",
            "alloc_512mb",
        ] {
            let v = got
                .get(k)
                .unwrap_or_else(|| panic!("子进程没有报告 {k}：{out}"));
            assert!(v.starts_with("denied"), "{k} 应被拒绝，实际 {v}");
        }
        assert_eq!(got["pipe_bytes"], "1000", "管道应当可用");
        println!("isolated_adversarial: all denied, pipe ok");
    }
}

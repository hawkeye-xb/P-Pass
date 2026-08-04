// DAE-01b blocker②: release builds bake the FULL tag into the binary.
//
// `CARGO_PKG_VERSION` carries no `-test.N` suffix, so a dogfood test.7 and
// test.8 daemon would both self-report 0.2.0 → version handshake sees
// Equal → the newer test package steps down and the takeover never fires.
// `.github/workflows/release.yml` sets `PPF_BUILD_VERSION` (tag, leading
// `v` stripped) on tag events; code falls back to `CARGO_PKG_VERSION`
// for local/dev builds (see `ipc::daemon_version`).

fn main() {
    println!("cargo:rerun-if-env-changed=PPF_BUILD_VERSION");
    if let Ok(v) = std::env::var("PPF_BUILD_VERSION") {
        let v = v.trim().trim_start_matches('v');
        if !v.is_empty() {
            println!("cargo:rustc-env=PPF_BUILD_VERSION={v}");
        }
    }
}

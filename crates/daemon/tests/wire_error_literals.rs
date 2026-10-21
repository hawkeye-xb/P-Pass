//! #1070 acceptance 7: wire errors carry `{code, reason, params}` only — no
//! localisation key. Production Rust under `crates/` and `tools/` must not
//! spell `msg_key` or an `"err.` literal, except:
//!
//! - the frozen v1 shim constant (`crates/proto/src/error.rs`, `V1_SHIM`);
//! - `diag.status`'s `msg_key` in `crates/daemon/src/ipc.rs` (a diagnosis
//!   state label for the bundled shell, not an error; out of #1070's scope).
//!
//! `crates/diag` is excluded: it is the UI text dictionary, not the wire.
//! Comment lines and each file's `#[cfg(test)] mod` (from there on) are skipped
//! (tests assert the absence / the shim, so they must name it).

use std::path::{Path, PathBuf};

const ALLOWED: &[(&str, &str)] = &[
    ("crates/proto/src/error.rs", "const V1_SHIM: [&str; 3]"),
    ("crates/daemon/src/ipc.rs", "\"msg_key\": state.msg_key(),"),
];

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .unwrap()
        .to_path_buf()
}

fn rust_sources(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if path.is_dir() {
            // Only production source trees; `tests/`, `target/` and the UI
            // dictionary crate are out.
            if name == "target" || name == "tests" || name == "diag" || name.starts_with('.') {
                continue;
            }
            rust_sources(&path, out);
        } else if name.ends_with(".rs") && path.components().any(|c| c.as_os_str() == "src") {
            out.push(path);
        }
    }
}

/// Offending `(file, line no, line)` triples in one source text.
fn offenders(rel: &str, src: &str) -> Vec<(String, usize, String)> {
    let mut hits = Vec::new();
    let lines: Vec<&str> = src.lines().collect();
    for (i, line) in lines.iter().enumerate() {
        let t = line.trim_start();
        // Stop only at a test *module*; a lone `#[cfg(test)]` fn or impl in
        // the middle of a file must not hide the production code after it.
        if t.starts_with("#[cfg(test)]")
            && lines
                .get(i + 1)
                .is_some_and(|next| next.trim_start().starts_with("mod "))
        {
            break;
        }
        if t.starts_with("//") {
            continue;
        }
        if !(line.contains("msg_key") || line.contains("\"err.")) {
            continue;
        }
        if ALLOWED
            .iter()
            .any(|(file, needle)| rel == *file && line.contains(needle))
        {
            continue;
        }
        hits.push((rel.to_string(), i + 1, line.trim().to_string()));
    }
    hits
}

#[test]
fn no_localisation_key_on_wire_errors() {
    let root = repo_root();
    let mut files = Vec::new();
    rust_sources(&root.join("crates"), &mut files);
    rust_sources(&root.join("tools"), &mut files);
    assert!(
        files
            .iter()
            .any(|f| f.ends_with("crates/daemon/src/router.rs")),
        "scanner must reach the daemon sources"
    );
    let mut hits = Vec::new();
    let mut allowed_seen = vec![false; ALLOWED.len()];
    for file in &files {
        let rel = file
            .strip_prefix(&root)
            .unwrap()
            .to_string_lossy()
            .replace('\\', "/");
        let src = std::fs::read_to_string(file).unwrap();
        for (k, (allowed_file, needle)) in ALLOWED.iter().enumerate() {
            if rel == *allowed_file && src.contains(needle) {
                allowed_seen[k] = true;
            }
        }
        hits.extend(offenders(&rel, &src));
    }
    assert!(
        hits.is_empty(),
        "wire errors must not carry a localisation key:\n{}",
        hits.iter()
            .map(|(f, n, l)| format!("  {f}:{n}: {l}"))
            .collect::<Vec<_>>()
            .join("\n")
    );
    // A stale allow-list entry would silently widen the gate.
    for (k, seen) in allowed_seen.iter().enumerate() {
        assert!(seen, "allow-list entry no longer matches: {:?}", ALLOWED[k]);
    }
}

/// Counter-proof for the scanner itself: the pre-v2 shapes are caught.
#[test]
fn the_scanner_catches_the_old_shapes() {
    let old = "fn f() {\n    RespError::new(codes::NOT_FOUND, \"err.not_found\");\n    let k = e.msg_key;\n}\n";
    assert_eq!(offenders("crates/daemon/src/x.rs", old).len(), 2);
    // ... but not inside comments or the trailing test module.
    let ok =
        "// msg_key was here\nfn f() {}\n#[cfg(test)]\nmod tests { const K: &str = \"err.x\"; }\n";
    assert!(offenders("crates/daemon/src/x.rs", ok).is_empty());
    // A lone test-only item mid-file does not end the scan.
    let mid = "#[cfg(test)]\nfn helper() {}\nfn prod() { let k = \"err.x\"; }\n";
    assert_eq!(offenders("crates/daemon/src/x.rs", mid).len(), 1);
    // The allow-list is per file.
    let shim = "const V1_SHIM: [&str; 3] = [\"msg_key\", \"err.unsupported\", \"fetch_failed\"];";
    assert!(offenders("crates/proto/src/error.rs", shim).is_empty());
    assert_eq!(offenders("crates/daemon/src/router.rs", shim).len(), 1);
}

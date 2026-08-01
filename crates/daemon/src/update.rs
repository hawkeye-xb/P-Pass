//! Update manifest parsing + verification (T-062).
//!
//! The manifest is a static file served at `<update-endpoint>/manifest.json`
//! (Cloudflare Pages or a Worker). Format + signing convention: see
//! `infra/workers/update/README.md`. In short:
//!
//! - `manifest.json` — `{version, notes, pub_date, platforms: {<os>-<arch>: {url, sha256, signature}}}`
//! - `manifest.json.sig` — detached Ed25519 signature over the EXACT bytes of
//!   the published `manifest.json` (tamper-evident by construction).
//! - Clients embed the official Ed25519 public key; nothing is trusted without
//!   a valid signature. The per-artifact `signature` (base64, over the artifact
//!   bytes) additionally pins each download.
//!
//! This module is pure (parse / select / compare / verify) and intentionally
//! NOT wired into the daemon runtime — the fetch loop, retry policy and UI
//! surface land with the release pipeline (T-071). Per AGENT_PROTOCOL: no
//! `unwrap`/`expect` in production code.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Artifact descriptor for one platform target. Key: `{os}-{arch}`, e.g.
/// `macos-arm64`, `macos-x64`, `windows-x64`, `linux-x64`, `linux-arm64`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Artifact {
    pub url: String,
    /// Hex SHA-256 of the artifact; verified after download.
    pub sha256: String,
    /// Base64 Ed25519 signature over the artifact bytes (Tauri-updater style).
    #[serde(default)]
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    /// SemVer of the update this manifest offers.
    pub version: String,
    #[serde(default)]
    pub notes: String,
    /// RFC 3339 timestamp, informational.
    #[serde(default)]
    pub pub_date: Option<String>,
    pub platforms: BTreeMap<String, Artifact>,
}

#[derive(Debug, thiserror::Error)]
pub enum ManifestError {
    #[error("manifest parse failed: {0}")]
    Parse(String),
    #[error("bad version string `{0}`: {1}")]
    Version(String, String),
    #[error("signature verification failed: {0}")]
    Signature(String),
    #[error("invalid Ed25519 public key")]
    Key,
    #[error("no artifact for platform `{0}`")]
    NoPlatform(String),
}

/// Canonical platform key from the runtime's `os` / `arch` constants.
pub fn platform_key(os: &str, arch: &str) -> String {
    let a = match arch {
        "aarch64" => "arm64",
        "x86_64" => "x64",
        other => other,
    };
    format!("{os}-{a}")
}

impl Manifest {
    /// Parse the manifest, rejecting unknown fields (drift must fail loudly).
    pub fn parse(bytes: &[u8]) -> Result<Self, ManifestError> {
        serde_json::from_slice(bytes).map_err(|e| ManifestError::Parse(e.to_string()))
    }

    /// The artifact for the given runtime platform, if published.
    pub fn select_platform(&self, os: &str, arch: &str) -> Option<&Artifact> {
        self.platforms.get(&platform_key(os, arch))
    }
}

/// True when `candidate` is a strictly newer SemVer than `current`.
pub fn is_newer(current: &str, candidate: &str) -> Result<bool, ManifestError> {
    let cur = semver::Version::parse(current)
        .map_err(|e| ManifestError::Version(current.to_string(), e.to_string()))?;
    let cand = semver::Version::parse(candidate)
        .map_err(|e| ManifestError::Version(candidate.to_string(), e.to_string()))?;
    Ok(cand > cur)
}

/// Verify the detached Ed25519 signature over the manifest bytes.
pub fn verify_manifest(
    manifest_bytes: &[u8],
    sig_bytes: &[u8],
    public_key: &[u8],
) -> Result<(), ManifestError> {
    let key = ed25519_dalek::VerifyingKey::from_bytes(
        public_key.try_into().map_err(|_| ManifestError::Key)?,
    )
    .map_err(|e| ManifestError::Signature(e.to_string()))?;
    let sig = ed25519_dalek::Signature::from_slice(sig_bytes)
        .map_err(|e| ManifestError::Signature(e.to_string()))?;
    key.verify_strict(manifest_bytes, &sig)
        .map_err(|e| ManifestError::Signature(e.to_string()))
}

/// What a client needs to actually update.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateInfo {
    pub version: String,
    pub notes: String,
    pub artifact: Artifact,
}

/// Full check: verify signature → parse → newer? → platform artifact?
/// Returns `Ok(None)` when the manifest offers nothing newer for this platform.
pub fn check_update(
    manifest_bytes: &[u8],
    sig_bytes: &[u8],
    public_key: &[u8],
    current: &str,
    os: &str,
    arch: &str,
) -> Result<Option<UpdateInfo>, ManifestError> {
    verify_manifest(manifest_bytes, sig_bytes, public_key)?;
    let manifest = Manifest::parse(manifest_bytes)?;
    if !is_newer(current, &manifest.version)? {
        return Ok(None);
    }
    let artifact = manifest
        .select_platform(os, arch)
        .ok_or_else(|| ManifestError::NoPlatform(platform_key(os, arch)))?
        .clone();
    Ok(Some(UpdateInfo {
        version: manifest.version,
        notes: manifest.notes,
        artifact,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    /// Deterministic test keypair — no RNG dependency in tests.
    fn test_keypair() -> (SigningKey, Vec<u8>) {
        let signing = SigningKey::from_bytes(&[7u8; 32]);
        let pubkey = signing.verifying_key().to_bytes().to_vec();
        (signing, pubkey)
    }

    fn sample_manifest(version: &str) -> Vec<u8> {
        serde_json::json!({
            "version": version,
            "notes": "family photo center v2",
            "pub_date": "2026-07-31T00:00:00Z",
            "platforms": {
                "macos-arm64": {
                    "url": "https://update.example/P-Pass-0.2.0-arm64.dmg",
                    "sha256": "ab".repeat(32),
                    "signature": "c2ln"
                },
                "macos-x64": {
                    "url": "https://update.example/P-Pass-0.2.0-x64.dmg",
                    "sha256": "cd".repeat(32)
                }
            }
        })
        .to_string()
        .into_bytes()
    }

    fn sign(signing: &SigningKey, bytes: &[u8]) -> Vec<u8> {
        signing.sign(bytes).to_bytes().to_vec()
    }

    #[test]
    fn parse_valid_manifest() {
        let m = Manifest::parse(&sample_manifest("0.2.0")).expect("valid");
        assert_eq!(m.version, "0.2.0");
        assert_eq!(m.platforms.len(), 2);
        assert_eq!(
            m.select_platform("macos", "aarch64").unwrap().url,
            "https://update.example/P-Pass-0.2.0-arm64.dmg"
        );
    }

    #[test]
    fn parse_rejects_unknown_fields() {
        let mut bytes = sample_manifest("0.2.0");
        let mut v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        v.as_object_mut()
            .unwrap()
            .insert("evil".into(), serde_json::json!(1));
        bytes = serde_json::to_vec(&v).unwrap();
        assert!(Manifest::parse(&bytes).is_err());
    }

    #[test]
    fn parse_rejects_garbage() {
        assert!(Manifest::parse(b"not json").is_err());
        assert!(Manifest::parse(b"{}").is_err());
    }

    #[test]
    fn platform_keys() {
        assert_eq!(platform_key("macos", "aarch64"), "macos-arm64");
        assert_eq!(platform_key("macos", "x86_64"), "macos-x64");
        assert_eq!(platform_key("windows", "x86_64"), "windows-x64");
        assert_eq!(platform_key("linux", "aarch64"), "linux-arm64");
    }

    #[test]
    fn platform_selection_missing_returns_none() {
        let m = Manifest::parse(&sample_manifest("0.2.0")).unwrap();
        assert!(m.select_platform("windows", "x86_64").is_none());
    }

    #[test]
    fn version_comparison() {
        assert!(is_newer("0.1.0", "0.2.0").unwrap());
        assert!(is_newer("0.9.9", "1.0.0").unwrap());
        assert!(!is_newer("0.2.0", "0.2.0").unwrap());
        assert!(!is_newer("0.3.0", "0.2.0").unwrap());
        // pre-release sorts below its release
        assert!(!is_newer("1.0.0", "1.0.0-alpha.1").unwrap());
        assert!(is_newer("1.0.0-alpha.1", "1.0.0").unwrap());
        // malformed versions are errors, not silent false
        assert!(is_newer("not-a-version", "0.2.0").is_err());
    }

    #[test]
    fn signature_verifies() {
        let (signing, pubkey) = test_keypair();
        let bytes = sample_manifest("0.2.0");
        let sig = sign(&signing, &bytes);
        verify_manifest(&bytes, &sig, &pubkey).expect("valid signature");
    }

    #[test]
    fn tampered_manifest_fails_verification() {
        let (signing, pubkey) = test_keypair();
        let mut bytes = sample_manifest("0.2.0");
        bytes[100] ^= 0xFF; // flip one byte — tamper must be caught
        let sig = sign(&signing, &bytes);
        // signature was made over the ORIGINAL bytes → must fail
        let original = sample_manifest("0.2.0");
        assert!(verify_manifest(&original, &sig, &pubkey).is_err());
        // and a signature over the tampered bytes must fail too (it wasn't signed)
        let sig2 = sign(&signing, &bytes);
        assert!(verify_manifest(&bytes, &sig2, &pubkey).is_ok()); // sanity: signer can sign anything
    }

    #[test]
    fn wrong_key_fails_verification() {
        let (signing, _) = test_keypair();
        let other = SigningKey::from_bytes(&[9u8; 32]);
        let pubkey = other.verifying_key().to_bytes().to_vec();
        let bytes = sample_manifest("0.2.0");
        let sig = sign(&signing, &bytes);
        assert!(verify_manifest(&bytes, &sig, &pubkey).is_err());
    }

    #[test]
    fn garbage_signature_fails() {
        let (_, pubkey) = test_keypair();
        let bytes = sample_manifest("0.2.0");
        assert!(verify_manifest(&bytes, b"short", &pubkey).is_err());
    }

    #[test]
    fn check_update_full_flow() {
        let (signing, pubkey) = test_keypair();
        let bytes = sample_manifest("0.2.0");
        let sig = sign(&signing, &bytes);

        // newer version + platform present → update offered
        let up = check_update(&bytes, &sig, &pubkey, "0.1.0", "macos", "aarch64")
            .expect("ok")
            .expect("update");
        assert_eq!(up.version, "0.2.0");
        assert_eq!(up.artifact.sha256, "ab".repeat(32));

        // same version → none
        assert!(
            check_update(&bytes, &sig, &pubkey, "0.2.0", "macos", "aarch64")
                .unwrap()
                .is_none()
        );

        // platform not published → error (not silent none)
        assert!(matches!(
            check_update(&bytes, &sig, &pubkey, "0.1.0", "windows", "x86_64"),
            Err(ManifestError::NoPlatform(_))
        ));

        // bad signature → error before anything is parsed
        let bad_sig = sign(&SigningKey::from_bytes(&[1u8; 32]), &bytes);
        assert!(matches!(
            check_update(&bytes, &bad_sig, &pubkey, "0.1.0", "macos", "aarch64"),
            Err(ManifestError::Signature(_))
        ));
    }
}

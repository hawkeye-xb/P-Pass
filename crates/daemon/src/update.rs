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

use base64::Engine as _;
use serde::{Deserialize, Deserializer, Serialize};
use sha2::Digest as _;

/// Official Ed25519 public key (base64, 32 bytes) — the release signing key.
///
/// T-062b: placeholder until the release pipeline (T-071) generates the real
/// keypair; the constant MUST exist and be exactly 32 bytes so the client
/// build fails loudly rather than silently accepting a missing key.
/// 占位符：T-071 生成真实密钥对后替换。客户端构建时必须存在且 32 字节。
pub const OFFICIAL_PUBLIC_KEY: &[u8] = &[
    // 32-byte placeholder — REPLACE with the real key before any release.
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

/// Deserialize a hex string and require exactly 64 hex chars (32 bytes).
fn de_sha256_hex<'de, D>(d: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let s = String::deserialize(d)?;
    if s.len() != 64 || !s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(serde::de::Error::custom(format!(
            "sha256 must be 64 hex chars, got `{}` (len {})",
            s,
            s.len()
        )));
    }
    Ok(s)
}

/// Deserialize a required non-empty base64 signature string.
fn de_signature<'de, D>(d: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let s = String::deserialize(d)?;
    if s.is_empty() {
        return Err(serde::de::Error::custom(
            "signature must be a non-empty base64 Ed25519 signature",
        ));
    }
    Ok(s)
}

/// Artifact descriptor for one platform target. Key: `{os}-{arch}`, e.g.
/// `macos-arm64`, `macos-x64`, `windows-x64`, `linux-x64`, `linux-arm64`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Artifact {
    pub url: String,
    /// Hex SHA-256 of the artifact; validated at parse time (64 hex chars) and
    /// verified against the downloaded bytes via [`verify_artifact`].
    #[serde(deserialize_with = "de_sha256_hex")]
    pub sha256: String,
    /// Base64 Ed25519 signature over the artifact bytes (Tauri-updater style).
    /// Required and non-empty — an empty/missing signature must fail loudly,
    /// never skip (T-062b: removed `#[serde(default)]`).
    #[serde(deserialize_with = "de_signature")]
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
    #[error("artifact verification failed: {0}")]
    Artifact(String),
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
    let key = verifying_key(public_key)?;
    let sig = ed25519_dalek::Signature::from_slice(sig_bytes)
        .map_err(|e| ManifestError::Signature(e.to_string()))?;
    key.verify_strict(manifest_bytes, &sig)
        .map_err(|e| ManifestError::Signature(e.to_string()))
}

/// Parse a 32-byte Ed25519 public key, mapping errors to [`ManifestError::Key`].
fn verifying_key(public_key: &[u8]) -> Result<ed25519_dalek::VerifyingKey, ManifestError> {
    ed25519_dalek::VerifyingKey::from_bytes(public_key.try_into().map_err(|_| ManifestError::Key)?)
        .map_err(|_| ManifestError::Key)
}

/// Verify a downloaded artifact: SHA-256 must match the manifest's hex digest
/// AND the artifact's Ed25519 signature must verify with the official key.
///
/// T-062b: this is the download half of the story that was missing — the
/// manifest carried `sha256`/`signature` fields but nothing enforced them.
/// Both checks must pass; a hash mismatch and a bad signature are both
/// hard errors (the artifact is discarded, never installed).
pub fn verify_artifact(
    artifact_bytes: &[u8],
    artifact: &Artifact,
    public_key: &[u8],
) -> Result<(), ManifestError> {
    // 1. SHA-256 hash check (hex digest from the manifest).
    let digest = sha2::Sha256::digest(artifact_bytes);
    let got = hex::encode(digest);
    if got != artifact.sha256 {
        return Err(ManifestError::Artifact(format!(
            "sha256 mismatch: manifest `{}`, got `{}`",
            artifact.sha256, got
        )));
    }
    // 2. Per-artifact Ed25519 signature (base64 over the artifact bytes).
    let sig_bytes = base64::engine::general_purpose::STANDARD
        .decode(artifact.signature.as_bytes())
        .map_err(|e| ManifestError::Artifact(format!("signature not base64: {e}")))?;
    let key = verifying_key(public_key)?;
    let sig = ed25519_dalek::Signature::from_slice(&sig_bytes)
        .map_err(|e| ManifestError::Artifact(format!("signature malformed: {e}")))?;
    key.verify_strict(artifact_bytes, &sig)
        .map_err(|e| ManifestError::Artifact(format!("signature invalid: {e}")))
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
                    "sha256": "cd".repeat(32),
                    "signature": "c2ln"
                }
            }
        })
        .to_string()
        .into_bytes()
    }

    /// Deterministic artifact bytes for verify_artifact tests. The manifest is
    /// built per-test via `signed_artifact_manifest` so its digest/signature
    /// always match these bytes.
    fn artifact_bytes_for() -> Vec<u8> {
        b"ppf-artifact-test-bytes-0123456789".to_vec()
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
        let original = sample_manifest("0.2.0");
        let sig = sign(&signing, &original);

        // sanity: original bytes + original signature → OK
        assert!(verify_manifest(&original, &sig, &pubkey).is_ok());

        // tamper one byte AFTER signing → must fail (that's the point)
        let mut tampered = original.clone();
        tampered[100] ^= 0xFF;
        assert!(
            verify_manifest(&tampered, &sig, &pubkey).is_err(),
            "tampered manifest must fail verification"
        );

        // a signature over the tampered bytes also fails against the original
        let sig_tampered = sign(&signing, &tampered);
        assert!(verify_manifest(&original, &sig_tampered, &pubkey).is_err());
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

    // ── T-062b: artifact verification + parse-time hardening ──────────────
    // base64::Engine (for `.encode`) comes in via `use super::*` — the
    // module-level import at the top of the file.

    /// Build a manifest whose artifact digest/signature match the given bytes.
    fn signed_artifact_manifest(signing: &SigningKey, artifact_bytes: &[u8]) -> (Vec<u8>, Vec<u8>) {
        let digest = sha2::Sha256::digest(artifact_bytes);
        let digest_hex = hex::encode(digest);
        let sig_b64 =
            base64::engine::general_purpose::STANDARD.encode(sign(signing, artifact_bytes));
        let m = serde_json::json!({
            "version": "0.2.0",
            "notes": "family photo center v2",
            "pub_date": "2026-07-31T00:00:00Z",
            "platforms": {
                "macos-arm64": {
                    "url": "https://update.example/P-Pass-0.2.0-arm64.dmg",
                    "sha256": digest_hex,
                    "signature": sig_b64
                }
            }
        })
        .to_string()
        .into_bytes();
        let sig = sign(signing, &m);
        (m, sig)
    }

    #[test]
    fn official_public_key_exists_and_is_32_bytes() {
        // T-062b: the key constant must exist and be exactly 32 bytes so a
        // missing key fails at build time, not at first update check.
        assert_eq!(OFFICIAL_PUBLIC_KEY.len(), 32);
    }

    #[test]
    fn verify_artifact_accepts_matching_hash_and_signature() {
        let (signing, pubkey) = test_keypair();
        let bytes = artifact_bytes_for();
        let (m, msig) = signed_artifact_manifest(&signing, &bytes);
        let manifest = Manifest::parse(&m).unwrap();
        let artifact = manifest.select_platform("macos", "aarch64").unwrap();
        // manifest signature still verifies (sanity)
        verify_manifest(&m, &msig, &pubkey).unwrap();
        verify_artifact(&bytes, artifact, &pubkey).expect("hash + sig match");
    }

    #[test]
    fn verify_artifact_rejects_wrong_hash() {
        let (signing, pubkey) = test_keypair();
        let bytes = artifact_bytes_for();
        let (m, _) = signed_artifact_manifest(&signing, &bytes);
        let manifest = Manifest::parse(&m).unwrap();
        let artifact = manifest.select_platform("macos", "aarch64").unwrap();
        // flip one byte → digest no longer matches
        let mut corrupt = bytes.clone();
        corrupt[3] ^= 0xFF;
        let err = verify_artifact(&corrupt, artifact, &pubkey).unwrap_err();
        assert!(matches!(err, ManifestError::Artifact(e) if e.contains("sha256 mismatch")));
    }

    #[test]
    fn verify_artifact_rejects_wrong_signature() {
        let (signing, pubkey) = test_keypair();
        let bytes = artifact_bytes_for();
        let (m, _) = signed_artifact_manifest(&signing, &bytes);
        let manifest = Manifest::parse(&m).unwrap();
        let artifact = manifest.select_platform("macos", "aarch64").unwrap();
        // same bytes, but a signature from a different key → must fail even
        // though the hash matches
        let attacker = SigningKey::from_bytes(&[4u8; 32]);
        let mut forged = artifact.clone();
        forged.signature =
            base64::engine::general_purpose::STANDARD.encode(sign(&attacker, &bytes));
        let err = verify_artifact(&bytes, &forged, &pubkey).unwrap_err();
        assert!(matches!(err, ManifestError::Artifact(e) if e.contains("signature")));
    }

    #[test]
    fn verify_artifact_rejects_malformed_base64_signature() {
        let (_, pubkey) = test_keypair();
        let bytes = artifact_bytes_for();
        let (m, _) = signed_artifact_manifest(&SigningKey::from_bytes(&[7u8; 32]), &bytes);
        let manifest = Manifest::parse(&m).unwrap();
        let artifact = manifest.select_platform("macos", "aarch64").unwrap();
        let mut bad = artifact.clone();
        bad.signature = "!!!not-base64!!!".into();
        assert!(matches!(
            verify_artifact(&bytes, &bad, &pubkey).unwrap_err(),
            ManifestError::Artifact(_)
        ));
    }

    #[test]
    fn sha256_must_be_64_hex_at_parse_time() {
        // short digest → parse fails
        let mut short = sample_manifest("0.2.0");
        let mut v: serde_json::Value = serde_json::from_slice(&short).unwrap();
        v["platforms"]["macos-arm64"]["sha256"] = serde_json::json!("abc");
        short = serde_json::to_vec(&v).unwrap();
        assert!(Manifest::parse(&short).is_err());

        // non-hex chars → parse fails
        let mut nonhex = sample_manifest("0.2.0");
        let mut v: serde_json::Value = serde_json::from_slice(&nonhex).unwrap();
        v["platforms"]["macos-arm64"]["sha256"] = serde_json::json!("zz".repeat(32));
        nonhex = serde_json::to_vec(&v).unwrap();
        assert!(Manifest::parse(&nonhex).is_err());
    }

    #[test]
    fn missing_signature_fails_parse_loudly() {
        // T-062b: signature no longer has #[serde(default)] — a manifest
        // without a per-artifact signature must fail to parse (loud, not skip).
        let mut bytes = sample_manifest("0.2.0");
        let mut v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        v["platforms"]["macos-arm64"]
            .as_object_mut()
            .unwrap()
            .remove("signature");
        bytes = serde_json::to_vec(&v).unwrap();
        assert!(
            Manifest::parse(&bytes).is_err(),
            "artifact without signature must be rejected"
        );
    }

    #[test]
    fn empty_signature_fails_parse_loudly() {
        let mut bytes = sample_manifest("0.2.0");
        let mut v: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        v["platforms"]["macos-arm64"]["signature"] = serde_json::json!("");
        bytes = serde_json::to_vec(&v).unwrap();
        assert!(
            Manifest::parse(&bytes).is_err(),
            "empty signature must be rejected"
        );
    }
}

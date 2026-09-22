//! Veya's in-process iOS bundle signing core.
//!
//! The public API deliberately accepts key bytes instead of a macOS Keychain
//! identity. This keeps iOS payload signing independent from `SecIdentity`,
//! SecurityAgent, and external `codesign` processes.

use apple_codesign::{
    MachFile, SettingsScope, SigningSettings, UnifiedSigner, cryptography::InMemoryPrivateKey,
    verify_macho_data,
};
mod profile_cms;
use plist::{Dictionary as PlistDictionary, Value as PlistValue};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::{Cursor, Read, Write},
    path::{Component, Path, PathBuf},
};
use tempfile::Builder as TempBuilder;
use thiserror::Error;
use x509_certificate::CapturedX509Certificate as X509Certificate;
use zeroize::Zeroizing;

#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};

pub const SIGNING_CORE_ABI_VERSION: u32 = 1;
const GRAPH_SCHEMA_VERSION: u32 = 1;
const MAX_KEY_BYTES: usize = 64 * 1024;
const MAX_CERTIFICATE_BYTES: usize = 1024 * 1024;
const MAX_PROFILE_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BundleNodeKind {
    Bundle,
    MachO,
    Resource,
    Symlink,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleNode {
    pub relative_path: String,
    pub kind: BundleNodeKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bundle_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub symlink_target: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleGraph {
    pub schema_version: u32,
    pub root_bundle_id: String,
    pub nodes: Vec<BundleNode>,
    pub inventory_sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExpectedBundleGraph {
    pub schema_version: u32,
    pub root_bundle_id: String,
    pub signable_nodes: Vec<ExpectedSignableNode>,
    pub inventory_sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExpectedSignableNode {
    pub relative_path: String,
    pub kind: BundleNodeKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bundle_id: Option<String>,
}

impl ExpectedBundleGraph {
    pub fn from_graph(graph: &BundleGraph) -> Self {
        let signable_nodes = graph
            .nodes
            .iter()
            .filter(|node| matches!(node.kind, BundleNodeKind::Bundle | BundleNodeKind::MachO))
            .map(|node| ExpectedSignableNode {
                relative_path: node.relative_path.clone(),
                kind: node.kind.clone(),
                bundle_id: node.bundle_id.clone(),
            })
            .collect();
        Self {
            schema_version: graph.schema_version,
            root_bundle_id: graph.root_bundle_id.clone(),
            signable_nodes,
            inventory_sha256: graph.inventory_sha256.clone(),
        }
    }
}

// Deliberately no Debug: Zeroizing's Debug does not redact its contents.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SignRequest {
    pub input_bundle: PathBuf,
    pub output_bundle: PathBuf,
    #[serde(skip)]
    pub pkcs8: Zeroizing<Vec<u8>>,
    pub certificate_chain_der: Vec<Vec<u8>>,
    pub profiles: BTreeMap<String, Vec<u8>>,
    pub entitlements: BTreeMap<String, PlistDictionary>,
    pub expected: ExpectedBundleGraph,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VerifiedMachO {
    pub relative_path: String,
    pub sha256: String,
    pub mode: u32,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SigningReceipt {
    pub schema_version: u32,
    pub signing_core: String,
    pub input_inventory_sha256: String,
    pub output_inventory_sha256: String,
    pub root_bundle_id: String,
    pub verified_machos: Vec<VerifiedMachO>,
    pub embedded_profile_bundle_ids: Vec<String>,
    pub entitlement_bundle_ids: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VerificationReceipt {
    pub schema_version: u32,
    pub root_bundle_id: String,
    pub inventory_sha256: String,
    pub verified_machos: Vec<VerifiedMachO>,
}

#[derive(Debug, Error)]
pub enum SigningError {
    #[error("invalid signing request: {0}")]
    InvalidRequest(String),
    #[error("unsafe bundle path: {0}")]
    UnsafePath(String),
    #[error("bundle inventory mismatch: {0}")]
    InventoryMismatch(String),
    #[error("bundle I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("property list failed: {0}")]
    Plist(#[from] plist::Error),
    #[error("signing failed: {0}")]
    Signing(String),
    #[error("signed Mach-O verification failed for {path}: {problems}")]
    Verification { path: String, problems: String },
    #[error("signing operation was cancelled")]
    Cancelled,
}

pub fn inspect_bundle(path: impl AsRef<Path>) -> Result<BundleGraph, SigningError> {
    let root = path.as_ref();
    let metadata = fs::symlink_metadata(root)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(SigningError::InvalidRequest(
            "input bundle must be a real directory".to_string(),
        ));
    }

    let root_bundle_id = read_bundle_id(root)?.ok_or_else(|| {
        SigningError::InvalidRequest("root bundle has no CFBundleIdentifier".to_string())
    })?;
    let mut nodes = Vec::new();
    walk_inventory(root, root, &mut nodes)?;
    nodes.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
    let inventory_sha256 = inventory_digest(&root_bundle_id, &nodes)?;

    Ok(BundleGraph {
        schema_version: GRAPH_SCHEMA_VERSION,
        root_bundle_id,
        nodes,
        inventory_sha256,
    })
}

pub fn sign_and_verify(request: SignRequest) -> Result<SigningReceipt, SigningError> {
    sign_and_verify_with_cancel(request, || false)
}

pub fn sign_and_verify_with_cancel(
    request: SignRequest,
    cancelled: impl Fn() -> bool,
) -> Result<SigningReceipt, SigningError> {
    sign_with_profile_decoder(request, cancelled, decode_cms_profile)
}

// Tests may supply a synthetic profile decoder to qualify the signing primitive
// with an ephemeral self-signed certificate. Production always uses OS CMS trust.
fn sign_with_profile_decoder(
    request: SignRequest,
    cancelled: impl Fn() -> bool,
    decode: impl Fn(&[u8]) -> Result<PlistDictionary, SigningError>,
) -> Result<SigningReceipt, SigningError> {
    check_cancelled(&cancelled)?;
    validate_request(&request)?;
    let before = inspect_bundle(&request.input_bundle)?;
    compare_expected(&before, &request.expected)?;
    // The pinned library's filesystem layer (isideload-vfs DirEntry::file_type)
    // follows links, sealing a symlink as its target's bytes; Apple then rejects
    // the seal. iOS bundles are flat, so refuse before any mutation.
    if before
        .nodes
        .iter()
        .any(|n| n.kind == BundleNodeKind::Symlink)
    {
        return Err(SigningError::InvalidRequest(
            "bundle symlinks are not supported for iOS payload signing".into(),
        ));
    }
    reconcile_profiles_and_entitlements(
        &before,
        &request.certificate_chain_der,
        &request.profiles,
        &request.entitlements,
        &decode,
    )?;
    check_cancelled(&cancelled)?;
    let source_parent = request.input_bundle.parent().ok_or_else(|| {
        SigningError::InvalidRequest("input bundle has no parent directory".to_string())
    })?;
    let output_parent = request.output_bundle.parent().ok_or_else(|| {
        SigningError::InvalidRequest("output bundle has no parent directory".to_string())
    })?;
    // The transaction owns staging-directory creation. Requiring it to exist
    // prevents a rejected overlapping output from modifying the source tree.
    let canonical_input = fs::canonicalize(&request.input_bundle)?;
    let canonical_parent = fs::canonicalize(output_parent)?;
    if canonical_parent.starts_with(&canonical_input)
        || canonical_input.starts_with(&request.output_bundle)
    {
        return Err(SigningError::UnsafePath("source and output overlap".into()));
    }
    require_same_volume(source_parent, output_parent)?;
    if fs::symlink_metadata(&request.output_bundle).is_ok() {
        return Err(SigningError::InvalidRequest(
            "output bundle already exists".to_string(),
        ));
    }

    let temp = TempBuilder::new()
        .prefix(".veya-signing-")
        .tempdir_in(output_parent)?;
    let signed = temp.path().join("signed.app");
    // Sign in place only inside the disposable candidate. In the pinned
    // library's out-of-place mode, a flat iOS parent's resource walk omits
    // newly generated nested _CodeSignature files absent from the input tree.
    let prepared = signed.clone();
    copy_tree_safely(&request.input_bundle, &prepared)?;
    check_cancelled(&cancelled)?;
    inject_profiles(&prepared, &before, &request.profiles)?;

    let private_key = InMemoryPrivateKey::from_pkcs8_der(request.pkcs8.as_slice())
        .map_err(|error| SigningError::Signing(redact_error(error)))?;
    let leaf_der = request
        .certificate_chain_der
        .first()
        .ok_or_else(|| SigningError::InvalidRequest("certificate chain is empty".to_string()))?;
    let leaf = X509Certificate::from_der(leaf_der.clone())
        .map_err(|error| SigningError::Signing(redact_error(error)))?;
    let mut settings = SigningSettings::default();
    settings.set_signing_key(&private_key, leaf);
    for certificate in request.certificate_chain_der.iter().skip(1) {
        settings
            .chain_certificate_der(certificate)
            .map_err(|error| SigningError::Signing(redact_error(error)))?;
    }
    let _ = settings.chain_apple_certificates();
    let _ = settings.set_team_id_from_signing_certificate();
    settings.set_shallow(false);
    apply_entitlements(&mut settings, &before, &request.entitlements, &prepared)?;
    check_cancelled(&cancelled)?;

    UnifiedSigner::new(settings)
        .sign_path(&prepared, &signed)
        .map_err(|error| SigningError::Signing(redact_error(error)))?;
    check_cancelled(&cancelled)?;

    for node in before
        .nodes
        .iter()
        .filter(|n| n.kind == BundleNodeKind::MachO)
    {
        if let Some(mode) = node.mode {
            #[cfg(unix)]
            fs::set_permissions(
                signed.join(&node.relative_path),
                fs::Permissions::from_mode(mode),
            )?;
        }
    }
    let verified_machos = verify_signed_machos(&signed)?;
    verify_signed_entitlements(&signed, &before, &request.entitlements)?;
    verify_with_apple(&signed)?;
    let after = inspect_bundle(&signed)?;
    verify_preserved_structure(&before, &after, &request.profiles)?;
    let source_after = inspect_bundle(&request.input_bundle)?;
    if source_after != before {
        return Err(SigningError::InventoryMismatch(
            "immutable source changed during signing".to_string(),
        ));
    }
    check_cancelled(&cancelled)?;

    publish_exclusively(&signed, &request.output_bundle)?;
    sync_parent(output_parent)?;

    Ok(SigningReceipt {
        schema_version: 1,
        signing_core: format!(
            "veya-signing-core/{} apple-codesign/0.29.11",
            env!("CARGO_PKG_VERSION")
        ),
        input_inventory_sha256: before.inventory_sha256,
        output_inventory_sha256: after.inventory_sha256,
        root_bundle_id: before.root_bundle_id,
        verified_machos,
        embedded_profile_bundle_ids: request.profiles.keys().cloned().collect(),
        entitlement_bundle_ids: request.entitlements.keys().cloned().collect(),
    })
}

pub fn verify_bundle(path: impl AsRef<Path>) -> Result<VerificationReceipt, SigningError> {
    let graph = inspect_bundle(path.as_ref())?;
    let verified_machos = verify_signed_machos(path.as_ref())?;
    verify_with_apple(path.as_ref())?;
    Ok(VerificationReceipt {
        schema_version: 1,
        root_bundle_id: graph.root_bundle_id,
        inventory_sha256: graph.inventory_sha256,
        verified_machos,
    })
}

#[cfg(target_os = "macos")]
fn verify_with_apple(path: &Path) -> Result<(), SigningError> {
    use core_foundation::{base::TCFType, url::CFURL};
    use security_framework::os::macos::code_signing::{Flags, SecStaticCode};
    let failure = || SigningError::Verification {
        path: "bundle".into(),
        problems: "Apple static signature/resource verification failed".into(),
    };
    let url = CFURL::from_path(path, true).ok_or_else(failure)?;
    let code = SecStaticCode::from_path(&url, Flags::NONE).map_err(|_| failure())?;
    let flags = Flags::CHECK_ALL_ARCHITECTURES
        | Flags::CHECK_NESTED_CODE
        | Flags::STRICT_VALIDATE
        | Flags::NO_NETWORK_ACCESS;
    // SAFETY: a live OS object and documented null optional requirement. All
    // executable, nested-code, and resource validation flags remain enabled.
    let status = unsafe {
        security_framework_sys::code_signing::SecStaticCodeCheckValidity(
            code.as_concrete_TypeRef(),
            flags.bits(),
            std::ptr::null_mut(),
        )
    };
    #[cfg(test)]
    if status != 0 {
        let diagnostic = std::process::Command::new("/usr/bin/codesign")
            .args(["--verify", "--deep", "--strict", "--verbose=4"])
            .arg(path)
            .output()
            .unwrap();
        eprintln!(
            "Independent fixture verifier: {}",
            String::from_utf8_lossy(&diagnostic.stderr)
        );
        for node in inspect_bundle(path)?
            .nodes
            .iter()
            .filter(|n| n.kind == BundleNodeKind::Bundle || n.kind == BundleNodeKind::MachO)
        {
            let result = std::process::Command::new("/usr/bin/codesign")
                .args(["--verify", "--strict", "--verbose=4"])
                .arg(path.join(&node.relative_path))
                .output()
                .unwrap();
            eprintln!(
                "{}: {}",
                node.relative_path,
                String::from_utf8_lossy(&result.stderr)
            );
        }
        eprintln!(
            "resources: {}",
            fs::read_to_string(path.join("_CodeSignature/CodeResources")).unwrap_or_default()
        );
    }
    if status == 0 {
        Ok(())
    } else {
        Err(SigningError::Verification {
            path: "bundle".into(),
            problems: format!("Apple static signature/resource verification failed ({status})"),
        })
    }
}

#[cfg(not(target_os = "macos"))]
fn verify_with_apple(_path: &Path) -> Result<(), SigningError> {
    Err(SigningError::InvalidRequest(
        "independent verification requires macOS".into(),
    ))
}

fn check_cancelled(cancelled: &impl Fn() -> bool) -> Result<(), SigningError> {
    if cancelled() {
        Err(SigningError::Cancelled)
    } else {
        Ok(())
    }
}

fn validate_request(request: &SignRequest) -> Result<(), SigningError> {
    if request.pkcs8.is_empty() || request.pkcs8.len() > MAX_KEY_BYTES {
        return Err(SigningError::InvalidRequest(
            "PKCS#8 length is outside the supported range".to_string(),
        ));
    }
    if request.certificate_chain_der.is_empty()
        || request
            .certificate_chain_der
            .iter()
            .any(|cert| cert.is_empty() || cert.len() > MAX_CERTIFICATE_BYTES)
    {
        return Err(SigningError::InvalidRequest(
            "certificate chain is empty or oversized".to_string(),
        ));
    }
    if request
        .profiles
        .values()
        .any(|profile| profile.is_empty() || profile.len() > MAX_PROFILE_BYTES)
    {
        return Err(SigningError::InvalidRequest(
            "provisioning profile is empty or oversized".to_string(),
        ));
    }
    for (bundle_id, entitlements) in &request.entitlements {
        validate_entitlements(bundle_id, entitlements)?;
    }
    Ok(())
}

fn compare_expected(
    actual: &BundleGraph,
    expected: &ExpectedBundleGraph,
) -> Result<(), SigningError> {
    if expected.schema_version != GRAPH_SCHEMA_VERSION {
        return Err(SigningError::InventoryMismatch(format!(
            "unsupported expected graph schema {}",
            expected.schema_version
        )));
    }
    let actual_expected = ExpectedBundleGraph::from_graph(actual);
    if &actual_expected != expected {
        return Err(SigningError::InventoryMismatch(
            "source bundle differs from the approved manifest".to_string(),
        ));
    }
    Ok(())
}

fn walk_inventory(
    root: &Path,
    current: &Path,
    nodes: &mut Vec<BundleNode>,
) -> Result<(), SigningError> {
    if nodes.len() > 100_000
        || current
            .strip_prefix(root)
            .map(|p| p.components().count())
            .unwrap_or(0)
            > 64
    {
        return Err(SigningError::InvalidRequest(
            "bundle inventory limit exceeded".into(),
        ));
    }
    let mut entries = fs::read_dir(current)?.collect::<Result<Vec<_>, _>>()?;
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = entry.path();
        let relative = path
            .strip_prefix(root)
            .map_err(|_| SigningError::UnsafePath(path.display().to_string()))?;
        let relative_string = slash_path(relative)?;
        let metadata = fs::symlink_metadata(&path)?;
        if metadata.file_type().is_symlink() {
            let target = fs::read_link(&path)?;
            validate_relative_symlink(root, relative, &target)?;
            nodes.push(BundleNode {
                relative_path: relative_string,
                kind: BundleNodeKind::Symlink,
                bundle_id: None,
                sha256: None,
                mode: mode(&metadata),
                symlink_target: Some(slash_path(&target)?),
            });
        } else if metadata.is_dir() {
            if let Some(bundle_id) = read_bundle_id(&path)? {
                nodes.push(BundleNode {
                    relative_path: relative_string.clone(),
                    kind: BundleNodeKind::Bundle,
                    bundle_id: Some(bundle_id),
                    sha256: None,
                    mode: mode(&metadata),
                    symlink_target: None,
                });
            }
            walk_inventory(root, &path, nodes)?;
        } else if metadata.is_file() {
            let kind = if is_macho(&path)? {
                BundleNodeKind::MachO
            } else {
                BundleNodeKind::Resource
            };
            nodes.push(BundleNode {
                relative_path: relative_string,
                kind,
                bundle_id: None,
                sha256: Some(file_sha256(&path)?),
                mode: mode(&metadata),
                symlink_target: None,
            });
        } else {
            return Err(SigningError::UnsafePath(format!(
                "unsupported file type at {}",
                path.display()
            )));
        }
    }
    Ok(())
}

fn read_bundle_id(bundle: &Path) -> Result<Option<String>, SigningError> {
    let candidates = [
        bundle.join("Info.plist"),
        bundle.join("Contents/Info.plist"),
    ];
    for candidate in candidates {
        if !candidate.is_file() {
            continue;
        }
        let value = PlistValue::from_file(&candidate)?;
        let bundle_id = value
            .as_dictionary()
            .and_then(|dictionary| dictionary.get("CFBundleIdentifier"))
            .and_then(PlistValue::as_string)
            .map(str::to_string);
        return Ok(bundle_id);
    }
    Ok(None)
}

fn validate_relative_symlink(
    root: &Path,
    relative: &Path,
    target: &Path,
) -> Result<(), SigningError> {
    if target.is_absolute() {
        return Err(SigningError::UnsafePath(format!(
            "absolute symlink {} -> {}",
            relative.display(),
            target.display()
        )));
    }
    let parent = relative.parent().unwrap_or_else(|| Path::new(""));
    let mut depth = 0_i64;
    for component in parent.components().chain(target.components()) {
        match component {
            Component::Normal(_) => depth += 1,
            Component::ParentDir => {
                depth -= 1;
                if depth < 0 {
                    return Err(SigningError::UnsafePath(format!(
                        "escaping symlink {} -> {}",
                        relative.display(),
                        target.display()
                    )));
                }
            }
            Component::CurDir => {}
            _ => {
                return Err(SigningError::UnsafePath(format!(
                    "unsupported symlink {} -> {}",
                    relative.display(),
                    target.display()
                )));
            }
        }
    }
    if !fs::canonicalize(root.join(relative))?.starts_with(fs::canonicalize(root)?) {
        return Err(SigningError::UnsafePath(
            "symlink resolves outside bundle".into(),
        ));
    }
    Ok(())
}

fn copy_tree_safely(source: &Path, destination: &Path) -> Result<(), SigningError> {
    copy_tree_from_root(source, source, destination)
}

fn copy_tree_from_root(root: &Path, source: &Path, destination: &Path) -> Result<(), SigningError> {
    fs::create_dir(destination)?;
    fs::set_permissions(destination, fs::symlink_metadata(source)?.permissions())?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let from = entry.path();
        let to = destination.join(entry.file_name());
        let metadata = fs::symlink_metadata(&from)?;
        if metadata.file_type().is_symlink() {
            let relative = from.strip_prefix(root).unwrap_or(&from);
            let target = fs::read_link(&from)?;
            validate_relative_symlink(root, relative, &target)?;
            #[cfg(unix)]
            symlink(target, to)?;
            #[cfg(not(unix))]
            return Err(SigningError::UnsafePath(
                "symlinked bundles require a Unix host".to_string(),
            ));
        } else if metadata.is_dir() {
            copy_tree_from_root(root, &from, &to)?;
        } else if metadata.is_file() {
            fs::copy(&from, &to)?;
            fs::set_permissions(&to, metadata.permissions())?;
        } else {
            return Err(SigningError::UnsafePath(from.display().to_string()));
        }
    }
    Ok(())
}

fn reconcile_profiles_and_entitlements(
    graph: &BundleGraph,
    certificate_chain_der: &[Vec<u8>],
    profiles: &BTreeMap<String, Vec<u8>>,
    entitlements: &BTreeMap<String, PlistDictionary>,
    decode: &impl Fn(&[u8]) -> Result<PlistDictionary, SigningError>,
) -> Result<(), SigningError> {
    let required_bundle_ids = provisioned_bundle_ids(graph);
    let profile_bundle_ids = profiles.keys().cloned().collect::<Vec<_>>();
    let entitlement_bundle_ids = entitlements.keys().cloned().collect::<Vec<_>>();
    if profile_bundle_ids != required_bundle_ids {
        return Err(SigningError::InvalidRequest(
            "provisioning profiles do not exactly cover the executable bundle graph".to_string(),
        ));
    }
    if entitlement_bundle_ids != required_bundle_ids {
        return Err(SigningError::InvalidRequest(
            "entitlements do not exactly cover the provisioned bundle graph".to_string(),
        ));
    }

    let leaf = certificate_chain_der
        .first()
        .ok_or_else(|| SigningError::InvalidRequest("certificate chain is empty".to_string()))?;
    let leaf_sha256 = hex_digest(leaf);
    let mut shared_team: Option<String> = None;
    for bundle_id in required_bundle_ids {
        let encoded = profiles.get(&bundle_id).ok_or_else(|| {
            SigningError::InvalidRequest(format!("missing profile for {bundle_id}"))
        })?;
        let profile = decode(encoded)?;
        let requested = entitlements.get(&bundle_id).ok_or_else(|| {
            SigningError::InvalidRequest(format!("missing entitlements for {bundle_id}"))
        })?;
        let team = reconcile_profile_dictionary(&bundle_id, &leaf_sha256, &profile, requested)?;
        if let Some(expected) = &shared_team {
            if expected != &team {
                return Err(SigningError::InvalidRequest(
                    "nested profiles use different team identifiers".to_string(),
                ));
            }
        } else {
            shared_team = Some(team);
        }
    }
    Ok(())
}

fn provisioned_bundle_ids(graph: &BundleGraph) -> Vec<String> {
    let mut values = vec![graph.root_bundle_id.clone()];
    values.extend(graph.nodes.iter().filter_map(|node| {
        if node.kind == BundleNodeKind::Bundle
            && (node.relative_path.ends_with(".app") || node.relative_path.ends_with(".appex"))
        {
            node.bundle_id.clone()
        } else {
            None
        }
    }));
    values.sort();
    values.dedup();
    values
}

fn decode_cms_profile(encoded: &[u8]) -> Result<PlistDictionary, SigningError> {
    let plist_bytes = profile_cms::verify_and_decode(encoded)?;
    let value = PlistValue::from_reader(Cursor::new(plist_bytes))?;
    value.into_dictionary().ok_or_else(|| {
        SigningError::InvalidRequest("provisioning profile payload is not a dictionary".to_string())
    })
}

fn reconcile_profile_dictionary(
    bundle_id: &str,
    leaf_certificate_sha256: &str,
    profile: &PlistDictionary,
    requested: &PlistDictionary,
) -> Result<String, SigningError> {
    let now = std::time::SystemTime::now();
    let created = profile
        .get("CreationDate")
        .and_then(PlistValue::as_date)
        .map(std::time::SystemTime::from);
    let expires = profile
        .get("ExpirationDate")
        .and_then(PlistValue::as_date)
        .map(std::time::SystemTime::from);
    if !matches!((created, expires), (Some(start), Some(end)) if start <= now && now < end) {
        return Err(SigningError::InvalidRequest(
            "profile validity interval is invalid or expired".into(),
        ));
    }
    let team_identifiers = profile
        .get("TeamIdentifier")
        .and_then(PlistValue::as_array)
        .ok_or_else(|| {
            SigningError::InvalidRequest("profile has no team identifier".to_string())
        })?;
    let team = team_identifiers
        .first()
        .and_then(PlistValue::as_string)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            SigningError::InvalidRequest("profile has no team identifier".to_string())
        })?;
    if team_identifiers.len() != 1 {
        return Err(SigningError::InvalidRequest(
            "profile has ambiguous team identifiers".to_string(),
        ));
    }
    let prefixes = profile
        .get("ApplicationIdentifierPrefix")
        .and_then(PlistValue::as_array)
        .ok_or_else(|| {
            SigningError::InvalidRequest("profile has no application identifier prefix".to_string())
        })?;
    if prefixes.len() != 1 || prefixes.first().and_then(PlistValue::as_string) != Some(team) {
        return Err(SigningError::InvalidRequest(
            "profile application identifier prefix does not match its team".to_string(),
        ));
    }
    let developer_certificates = profile
        .get("DeveloperCertificates")
        .and_then(PlistValue::as_array)
        .ok_or_else(|| {
            SigningError::InvalidRequest("profile has no developer certificates".to_string())
        })?;
    if !developer_certificates.iter().any(|value| {
        value
            .as_data()
            .map(|certificate| hex_digest(certificate) == leaf_certificate_sha256)
            .unwrap_or(false)
    }) {
        return Err(SigningError::InvalidRequest(
            "profile does not authorize the signing certificate".to_string(),
        ));
    }
    let grants = profile
        .get("Entitlements")
        .and_then(PlistValue::as_dictionary)
        .ok_or_else(|| {
            SigningError::InvalidRequest("profile has no entitlement grants".to_string())
        })?;
    let profile_application_identifier = grants
        .get("application-identifier")
        .and_then(PlistValue::as_string)
        .ok_or_else(|| {
            SigningError::InvalidRequest("profile has no application identifier grant".to_string())
        })?;
    let exact_application_identifier = format!("{team}.{bundle_id}");
    if !identifier_pattern_matches(
        profile_application_identifier,
        &exact_application_identifier,
    ) {
        return Err(SigningError::InvalidRequest(format!(
            "profile application identifier does not authorize {bundle_id}"
        )));
    }
    if requested
        .get("application-identifier")
        .and_then(PlistValue::as_string)
        != Some(exact_application_identifier.as_str())
    {
        return Err(SigningError::InvalidRequest(format!(
            "requested application identifier is not exact for {bundle_id}"
        )));
    }
    if requested
        .get("com.apple.developer.team-identifier")
        .and_then(PlistValue::as_string)
        != Some(team)
    {
        return Err(SigningError::InvalidRequest(format!(
            "requested team identifier does not match the profile for {bundle_id}"
        )));
    }

    for (key, value) in requested {
        if !allowed_entitlement(key) {
            return Err(SigningError::InvalidRequest(format!(
                "entitlement {key} is not in Veya's allowlist for {bundle_id}"
            )));
        }
        let grant = grants.get(key).ok_or_else(|| {
            SigningError::InvalidRequest(format!(
                "profile does not grant entitlement {key} for {bundle_id}"
            ))
        })?;
        // Wildcards have meaning only for identifier-valued grants. Capability
        // strings such as aps-environment must compare exactly.
        let wildcard = matches!(
            key.as_str(),
            "application-identifier"
                | "keychain-access-groups"
                | "com.apple.developer.icloud-container-identifiers"
                | "com.apple.developer.ubiquity-kvstore-identifier"
        );
        if !entitlement_value_is_granted(value, grant, wildcard) {
            return Err(SigningError::InvalidRequest(format!(
                "requested entitlement {key} exceeds the profile grant for {bundle_id}"
            )));
        }
    }
    Ok(team.to_string())
}

fn allowed_entitlement(key: &str) -> bool {
    matches!(
        key,
        "application-identifier"
            | "com.apple.developer.team-identifier"
            | "get-task-allow"
            | "keychain-access-groups"
            | "com.apple.security.application-groups"
            | "aps-environment"
            | "com.apple.developer.associated-domains"
            | "com.apple.developer.networking.networkextension"
            | "com.apple.developer.networking.vpn.api"
            | "com.apple.developer.icloud-container-identifiers"
            | "com.apple.developer.ubiquity-kvstore-identifier"
            | "com.apple.developer.icloud-services"
    )
}

fn entitlement_value_is_granted(
    requested: &PlistValue,
    granted: &PlistValue,
    wildcard: bool,
) -> bool {
    match (requested, granted) {
        (PlistValue::String(requested), PlistValue::String(granted)) => {
            if wildcard {
                !requested.contains('*') && identifier_pattern_matches(granted, requested)
            } else {
                requested == granted
            }
        }
        (PlistValue::Array(requested), PlistValue::Array(granted)) => {
            requested.iter().all(|item| {
                granted
                    .iter()
                    .any(|grant| entitlement_value_is_granted(item, grant, wildcard))
            })
        }
        (PlistValue::Dictionary(requested), PlistValue::Dictionary(granted)) => {
            requested.iter().all(|(key, value)| {
                granted
                    .get(key)
                    .is_some_and(|grant| entitlement_value_is_granted(value, grant, wildcard))
            })
        }
        _ => requested == granted,
    }
}

fn identifier_pattern_matches(pattern: &str, value: &str) -> bool {
    if pattern == value {
        return true;
    }
    if pattern == "*" {
        return true;
    }
    pattern.strip_suffix('*').is_some_and(|prefix| {
        !prefix.is_empty() && !prefix.contains('*') && value.starts_with(prefix)
    })
}

fn inject_profiles(
    root: &Path,
    graph: &BundleGraph,
    profiles: &BTreeMap<String, Vec<u8>>,
) -> Result<(), SigningError> {
    let bundle_paths = bundle_paths_by_id(root, graph)?;
    for (bundle_id, profile) in profiles {
        let path = bundle_paths.get(bundle_id).ok_or_else(|| {
            SigningError::InvalidRequest(format!(
                "profile targets unknown bundle identifier {bundle_id}"
            ))
        })?;
        let profile_path = path.join("embedded.mobileprovision");
        if fs::symlink_metadata(&profile_path).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(SigningError::UnsafePath(
                "profile destination is a symlink".into(),
            ));
        }
        let mut file = File::create(profile_path)?;
        file.write_all(profile)?;
        file.sync_all()?;
    }
    Ok(())
}

fn apply_entitlements(
    settings: &mut SigningSettings<'_>,
    graph: &BundleGraph,
    entitlements: &BTreeMap<String, PlistDictionary>,
    root: &Path,
) -> Result<(), SigningError> {
    // Explicit empty entitlements stop the library importing entitlements from
    // existing signatures on frameworks/dylibs or inheriting the root's grants.
    for node in graph
        .nodes
        .iter()
        .filter(|node| matches!(node.kind, BundleNodeKind::MachO | BundleNodeKind::Bundle))
    {
        let mut xml = Vec::new();
        PlistValue::Dictionary(PlistDictionary::new()).to_writer_xml(&mut xml)?;
        settings
            .set_entitlements_xml(
                SettingsScope::Path(node.relative_path.clone()),
                String::from_utf8(xml).unwrap(),
            )
            .map_err(|error| SigningError::Signing(redact_error(error)))?;
    }
    let bundle_relatives = bundle_relatives_by_id(graph)?;
    for (bundle_id, dictionary) in entitlements {
        let relative = bundle_relatives.get(bundle_id).ok_or_else(|| {
            SigningError::InvalidRequest(format!(
                "entitlements target unknown bundle identifier {bundle_id}"
            ))
        })?;
        let mut xml = Vec::new();
        PlistValue::Dictionary(dictionary.clone()).to_writer_xml(&mut xml)?;
        let xml = String::from_utf8(xml).map_err(|_| {
            SigningError::InvalidRequest("entitlements did not encode as UTF-8".to_string())
        })?;
        let scope = if relative.is_empty() {
            SettingsScope::Main
        } else {
            SettingsScope::Path(relative.clone())
        };
        settings
            .set_entitlements_xml(scope, xml.clone())
            .map_err(|error| SigningError::Signing(redact_error(error)))?;
        let info = PlistValue::from_file(root.join(relative).join("Info.plist"))?;
        let executable = info
            .as_dictionary()
            .and_then(|d| d.get("CFBundleExecutable"))
            .and_then(PlistValue::as_string)
            .filter(|s| !s.is_empty() && !s.contains('/') && *s != "." && *s != "..")
            .ok_or_else(|| {
                SigningError::InvalidRequest("invalid executable in provisioned bundle".into())
            })?;
        let path = if relative.is_empty() {
            executable.to_string()
        } else {
            format!("{relative}/{executable}")
        };
        settings
            .set_entitlements_xml(SettingsScope::Path(path), xml)
            .map_err(|error| SigningError::Signing(redact_error(error)))?;
    }
    Ok(())
}

fn verify_signed_entitlements(
    root: &Path,
    graph: &BundleGraph,
    requested: &BTreeMap<String, PlistDictionary>,
) -> Result<(), SigningError> {
    let mut executable_entitlements = BTreeMap::new();
    for (bundle_id, relative) in bundle_relatives_by_id(graph)? {
        let bundle = root.join(&relative);
        let info_path = if bundle.join("Info.plist").is_file() {
            bundle.join("Info.plist")
        } else {
            bundle.join("Contents/Info.plist")
        };
        let info = PlistValue::from_file(info_path)?;
        if let Some(executable) = info
            .as_dictionary()
            .and_then(|d| d.get("CFBundleExecutable"))
            .and_then(PlistValue::as_string)
        {
            if executable.contains('/') || executable == "." || executable == ".." {
                return Err(SigningError::UnsafePath("invalid bundle executable".into()));
            }
            let executable_path = if bundle.join("Contents/MacOS").is_dir() {
                bundle.join("Contents/MacOS").join(executable)
            } else {
                bundle.join(executable)
            };
            executable_entitlements.insert(
                executable_path,
                (
                    bundle_id.clone(),
                    requested.get(&bundle_id).cloned().unwrap_or_default(),
                ),
            );
        } else if requested.contains_key(&bundle_id) {
            return Err(SigningError::InvalidRequest(
                "provisioned bundle has no executable".into(),
            ));
        }
    }
    for node in graph
        .nodes
        .iter()
        .filter(|n| n.kind == BundleNodeKind::MachO)
    {
        let path = root.join(&node.relative_path);
        let expected = executable_entitlements.get(&path);
        let empty = PlistDictionary::new();
        let expected_entitlements = expected.map(|(_, d)| d).unwrap_or(&empty);
        let bytes = fs::read(&path)?;
        let mach = MachFile::parse(&bytes).map_err(|_| SigningError::Verification {
            path: node.relative_path.clone(),
            problems: "malformed Mach-O".into(),
        })?;
        for architecture in mach.iter_macho() {
            let validate = || -> Result<bool, apple_codesign::AppleCodesignError> {
                let Some(signature) = architecture.code_signature()? else {
                    return Ok(false);
                };
                let xml = signature.entitlements()?;
                let actual = match xml {
                    Some(xml) => PlistValue::from_reader(Cursor::new(xml.as_str().as_bytes()))
                        .ok()
                        .and_then(PlistValue::into_dictionary),
                    None => Some(PlistDictionary::new()),
                };
                if actual.as_ref() != Some(expected_entitlements) {
                    return Ok(false);
                }
                if let Some(der) = signature.entitlements_der()? {
                    let actual = PlistValue::from_reader(Cursor::new(der.plist_xml()?))
                        .ok()
                        .and_then(PlistValue::into_dictionary);
                    if actual.as_ref() != Some(expected_entitlements) {
                        return Ok(false);
                    }
                }
                if let Some((bundle_id, _)) = expected
                    && signature
                        .code_directory()?
                        .is_none_or(|cd| cd.ident.as_ref() != bundle_id)
                {
                    return Ok(false);
                }
                Ok(true)
            };
            if !validate().unwrap_or(false) {
                return Err(SigningError::Verification {
                    path: node.relative_path.clone(),
                    problems: "signature identifier or entitlements differ from approved values"
                        .into(),
                });
            }
        }
    }
    Ok(())
}

fn validate_entitlements(
    bundle_id: &str,
    dictionary: &PlistDictionary,
) -> Result<(), SigningError> {
    const FORBIDDEN_EXACT: &[&str] = &[
        "com.apple.private.security.no-container",
        "com.apple.system-task-ports",
        "platform-application",
        "task_for_pid-allow",
    ];
    for key in dictionary.keys() {
        if FORBIDDEN_EXACT.contains(&key.as_str()) || key.starts_with("com.apple.private.") {
            return Err(SigningError::InvalidRequest(format!(
                "forbidden entitlement {key} for {bundle_id}"
            )));
        }
    }
    if let Some(application_identifier) = dictionary
        .get("application-identifier")
        .and_then(PlistValue::as_string)
    {
        let suffix = application_identifier
            .split_once('.')
            .map(|(_, value)| value);
        if suffix != Some(bundle_id) && suffix != Some("*") {
            return Err(SigningError::InvalidRequest(format!(
                "application-identifier does not match {bundle_id}"
            )));
        }
    }
    Ok(())
}

fn verify_signed_machos(root: &Path) -> Result<Vec<VerifiedMachO>, SigningError> {
    let graph = inspect_bundle(root)?;
    let mut verified = Vec::new();
    for node in graph
        .nodes
        .iter()
        .filter(|node| node.kind == BundleNodeKind::MachO)
    {
        let path = root.join(&node.relative_path);
        let bytes = fs::read(&path)?;
        let problems = verify_macho_data(&bytes);
        if !problems.is_empty() {
            return Err(SigningError::Verification {
                path: node.relative_path.clone(),
                problems: problems
                    .iter()
                    .map(|problem| format!("{problem:?}"))
                    .collect::<Vec<_>>()
                    .join("; "),
            });
        }
        let mode = node.mode.unwrap_or_default();
        if mode & 0o111 == 0 {
            return Err(SigningError::Verification {
                path: node.relative_path.clone(),
                problems: "Mach-O lost executable mode".to_string(),
            });
        }
        verified.push(VerifiedMachO {
            relative_path: node.relative_path.clone(),
            sha256: node.sha256.clone().unwrap_or_default(),
            mode,
        });
    }
    if verified.is_empty() {
        return Err(SigningError::InvalidRequest(
            "bundle contains no Mach-O code".to_string(),
        ));
    }
    Ok(verified)
}

fn verify_preserved_structure(
    before: &BundleGraph,
    after: &BundleGraph,
    profiles: &BTreeMap<String, Vec<u8>>,
) -> Result<(), SigningError> {
    if before.root_bundle_id != after.root_bundle_id {
        return Err(SigningError::InventoryMismatch(
            "root bundle identifier changed".to_string(),
        ));
    }
    let before_signable = ExpectedBundleGraph::from_graph(before).signable_nodes;
    let after_signable = ExpectedBundleGraph::from_graph(after).signable_nodes;
    if before_signable != after_signable {
        return Err(SigningError::InventoryMismatch(
            "signable bundle graph changed during signing".to_string(),
        ));
    }
    let generated_profile_count = after
        .nodes
        .iter()
        .filter(|node| node.relative_path.ends_with("embedded.mobileprovision"))
        .count();
    if generated_profile_count < profiles.len() {
        return Err(SigningError::InventoryMismatch(
            "one or more provisioning profiles were not embedded".to_string(),
        ));
    }
    for (id, relative) in bundle_relatives_by_id(before)? {
        if let Some(bytes) = profiles.get(&id) {
            let profile_path = if relative.is_empty() {
                "embedded.mobileprovision".to_string()
            } else {
                format!("{relative}/embedded.mobileprovision")
            };
            if !after.nodes.iter().any(|n| {
                n.relative_path == profile_path
                    && n.sha256.as_deref() == Some(hex_digest(bytes).as_str())
            }) {
                return Err(SigningError::InventoryMismatch(
                    "embedded profile bytes changed".into(),
                ));
            }
        }
    }
    for node in &before.nodes {
        if matches!(node.kind, BundleNodeKind::Symlink | BundleNodeKind::MachO) {
            let Some(other) = after
                .nodes
                .iter()
                .find(|n| n.relative_path == node.relative_path)
            else {
                return Err(SigningError::InventoryMismatch(
                    "code or symlink removed".into(),
                ));
            };
            if node.mode != other.mode || node.symlink_target != other.symlink_target {
                return Err(SigningError::InventoryMismatch(
                    "executable mode or symlink target changed".into(),
                ));
            }
        }
    }

    let before_resources: BTreeMap<_, _> = before
        .nodes
        .iter()
        .filter(|node| {
            node.kind == BundleNodeKind::Resource
                && !is_generated_signing_path(&node.relative_path)
                && !node.relative_path.ends_with("embedded.mobileprovision")
        })
        .map(|node| (node.relative_path.as_str(), node.sha256.as_deref()))
        .collect();
    let after_resources: BTreeMap<_, _> = after
        .nodes
        .iter()
        .filter(|node| {
            node.kind == BundleNodeKind::Resource
                && !is_generated_signing_path(&node.relative_path)
                && !node.relative_path.ends_with("embedded.mobileprovision")
        })
        .map(|node| (node.relative_path.as_str(), node.sha256.as_deref()))
        .collect();
    if before_resources != after_resources {
        return Err(SigningError::InventoryMismatch(
            "non-code resources changed during signing".to_string(),
        ));
    }
    Ok(())
}

fn bundle_paths_by_id(
    root: &Path,
    graph: &BundleGraph,
) -> Result<BTreeMap<String, PathBuf>, SigningError> {
    let relatives = bundle_relatives_by_id(graph)?;
    Ok(relatives
        .into_iter()
        .map(|(id, relative)| {
            let path = if relative.is_empty() {
                root.to_path_buf()
            } else {
                root.join(relative)
            };
            (id, path)
        })
        .collect())
}

fn bundle_relatives_by_id(graph: &BundleGraph) -> Result<BTreeMap<String, String>, SigningError> {
    let mut result = BTreeMap::new();
    result.insert(graph.root_bundle_id.clone(), String::new());
    for node in graph
        .nodes
        .iter()
        .filter(|node| node.kind == BundleNodeKind::Bundle)
    {
        if let Some(bundle_id) = &node.bundle_id
            && result
                .insert(bundle_id.clone(), node.relative_path.clone())
                .is_some()
        {
            return Err(SigningError::InvalidRequest(format!(
                "duplicate bundle identifier {bundle_id}"
            )));
        }
    }
    Ok(result)
}

fn inventory_digest(root_bundle_id: &str, nodes: &[BundleNode]) -> Result<String, SigningError> {
    let bytes = serde_json::to_vec(&(root_bundle_id, nodes)).map_err(|error| {
        SigningError::InvalidRequest(format!("inventory serialization failed: {error}"))
    })?;
    Ok(hex_digest(&bytes))
}

fn file_sha256(path: &Path) -> Result<String, SigningError> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn hex_digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn is_macho(path: &Path) -> Result<bool, SigningError> {
    let mut file = File::open(path)?;
    let mut magic = [0_u8; 4];
    if file.read(&mut magic)? != magic.len() {
        return Ok(false);
    }
    Ok(matches!(
        u32::from_be_bytes(magic),
        0xfeedface | 0xfeedfacf | 0xcefaedfe | 0xcffaedfe | 0xcafebabe | 0xbebafeca
    ))
}

fn slash_path(path: &Path) -> Result<String, SigningError> {
    let mut parts = Vec::new();
    for component in path.components() {
        match component {
            Component::Normal(value) => parts.push(value.to_string_lossy().into_owned()),
            Component::CurDir => {}
            Component::ParentDir => parts.push("..".to_string()),
            _ => {
                return Err(SigningError::UnsafePath(path.display().to_string()));
            }
        }
    }
    Ok(parts.join("/"))
}

fn is_generated_signing_path(path: &str) -> bool {
    path.split('/')
        .any(|component| component == "_CodeSignature")
}

fn redact_error(error: impl std::fmt::Display) -> String {
    let value = error.to_string();
    let lower = value.to_ascii_lowercase();
    if ["private key", "pkcs8", "password", "token", "cookie"]
        .iter()
        .any(|needle| lower.contains(needle))
    {
        "signing material was rejected".to_string()
    } else {
        value
            .chars()
            .filter(|value| !value.is_control())
            .take(512)
            .collect()
    }
}

#[cfg(unix)]
fn mode(metadata: &fs::Metadata) -> Option<u32> {
    Some(metadata.permissions().mode() & 0o7777)
}

#[cfg(not(unix))]
fn mode(_metadata: &fs::Metadata) -> Option<u32> {
    None
}

#[cfg(unix)]
fn require_same_volume(left: &Path, right: &Path) -> Result<(), SigningError> {
    if fs::metadata(left)?.dev() != fs::metadata(right)?.dev() {
        return Err(SigningError::InvalidRequest(
            "input and candidate must be on the same volume".to_string(),
        ));
    }
    Ok(())
}

#[cfg(not(unix))]
fn require_same_volume(_left: &Path, _right: &Path) -> Result<(), SigningError> {
    Ok(())
}

fn sync_parent(path: &Path) -> Result<(), SigningError> {
    File::open(path)?.sync_all()?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn publish_exclusively(source: &Path, destination: &Path) -> Result<(), SigningError> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let from = CString::new(source.as_os_str().as_bytes())
        .map_err(|_| SigningError::UnsafePath("NUL in path".into()))?;
    let to = CString::new(destination.as_os_str().as_bytes())
        .map_err(|_| SigningError::UnsafePath("NUL in path".into()))?;
    // SAFETY: terminated paths remain live; RENAME_EXCL prevents races replacing
    // an existing candidate, including an empty directory or symlink.
    if unsafe {
        libc::renameatx_np(
            libc::AT_FDCWD,
            from.as_ptr(),
            libc::AT_FDCWD,
            to.as_ptr(),
            libc::RENAME_EXCL,
        )
    } != 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn publish_exclusively(_source: &Path, _destination: &Path) -> Result<(), SigningError> {
    Err(SigningError::InvalidRequest(
        "atomic exclusive publication requires macOS".into(),
    ))
}

#[cfg(test)]
mod qualification_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn minimal_bundle(root: &Path) -> PathBuf {
        let bundle = root.join("Fixture.app");
        fs::create_dir_all(&bundle).unwrap();
        let mut info = PlistDictionary::new();
        info.insert(
            "CFBundleIdentifier".to_string(),
            PlistValue::String("com.veya.fixture".to_string()),
        );
        info.insert(
            "CFBundlePackageType".to_string(),
            PlistValue::String("APPL".to_string()),
        );
        PlistValue::Dictionary(info)
            .to_file_xml(bundle.join("Info.plist"))
            .unwrap();
        fs::write(bundle.join("resource.txt"), b"fixture").unwrap();
        bundle
    }

    #[test]
    fn graph_is_stable_and_expected_manifest_detects_mutation() {
        let temp = tempfile::tempdir().unwrap();
        let bundle = minimal_bundle(temp.path());
        let graph = inspect_bundle(&bundle).unwrap();
        let expected = ExpectedBundleGraph::from_graph(&graph);
        compare_expected(&graph, &expected).unwrap();

        fs::write(bundle.join("resource.txt"), b"changed").unwrap();
        let changed = inspect_bundle(&bundle).unwrap();
        let error = compare_expected(&changed, &expected).unwrap_err();
        assert!(error.to_string().contains("approved manifest"));
    }

    #[cfg(unix)]
    #[test]
    fn escaping_symlink_is_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let bundle = minimal_bundle(temp.path());
        symlink("../../outside", bundle.join("escape")).unwrap();
        let error = inspect_bundle(&bundle).unwrap_err();
        assert!(matches!(error, SigningError::UnsafePath(_)));
    }

    #[test]
    fn private_entitlement_is_rejected() {
        let mut entitlements = PlistDictionary::new();
        entitlements.insert(
            "com.apple.private.example".to_string(),
            PlistValue::Boolean(true),
        );
        let error = validate_entitlements("com.veya.fixture", &entitlements).unwrap_err();
        assert!(error.to_string().contains("forbidden entitlement"));
    }

    #[test]
    fn receipts_do_not_have_a_private_key_field() {
        let receipt = SigningReceipt {
            schema_version: 1,
            signing_core: "test".to_string(),
            input_inventory_sha256: "a".repeat(64),
            output_inventory_sha256: "b".repeat(64),
            root_bundle_id: "com.veya.fixture".to_string(),
            verified_machos: Vec::new(),
            embedded_profile_bundle_ids: Vec::new(),
            entitlement_bundle_ids: Vec::new(),
        };
        let json = serde_json::to_string(&receipt).unwrap();
        assert!(!json.contains("pkcs8"));
        assert!(!json.contains("private"));
    }
}

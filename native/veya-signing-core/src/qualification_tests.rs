//! Synthetic signing qualification. The synthetic-profile decoder is private
//! to tests; these certificates/profiles cannot authorize an iPhone install.
use super::*;
use openssl::{
    asn1::Asn1Time,
    hash::MessageDigest,
    pkey::PKey,
    rsa::Rsa,
    x509::{X509, X509NameBuilder},
};
use std::{
    process::Command,
    time::{Duration, SystemTime},
};

fn dictionary() -> PlistDictionary {
    let mut d = PlistDictionary::new();
    d.insert(
        "application-identifier".into(),
        "TESTTEAM01.com.veya.fixture".into(),
    );
    d.insert(
        "com.apple.developer.team-identifier".into(),
        "TESTTEAM01".into(),
    );
    d.insert("get-task-allow".into(), true.into());
    d.insert(
        "keychain-access-groups".into(),
        PlistValue::Array(vec!["TESTTEAM01.com.veya.fixture".into()]),
    );
    d
}

fn profile(cert: &[u8], grants: PlistDictionary) -> PlistDictionary {
    let mut p = PlistDictionary::new();
    p.insert(
        "TeamIdentifier".into(),
        PlistValue::Array(vec!["TESTTEAM01".into()]),
    );
    p.insert(
        "ApplicationIdentifierPrefix".into(),
        PlistValue::Array(vec!["TESTTEAM01".into()]),
    );
    p.insert(
        "DeveloperCertificates".into(),
        PlistValue::Array(vec![PlistValue::Data(cert.to_vec())]),
    );
    p.insert(
        "CreationDate".into(),
        PlistValue::Date((SystemTime::now() - Duration::from_secs(60)).into()),
    );
    p.insert(
        "ExpirationDate".into(),
        PlistValue::Date((SystemTime::now() + Duration::from_secs(3600)).into()),
    );
    p.insert("Entitlements".into(), PlistValue::Dictionary(grants));
    p
}

#[test]
fn grants_are_exact_or_scoped_wildcards_never_arbitrary_capabilities() {
    let cert = b"public fixture cert";
    let requested = dictionary();
    let mut grants = requested.clone();
    grants.insert(
        "application-identifier".into(),
        "TESTTEAM01.com.veya.*".into(),
    );
    grants.insert(
        "keychain-access-groups".into(),
        PlistValue::Array(vec!["TESTTEAM01.*".into()]),
    );
    let p = profile(cert, grants);
    assert!(
        reconcile_profile_dictionary("com.veya.fixture", &hex_digest(cert), &p, &requested).is_ok()
    );
    for (key, value) in [
        (
            "application-identifier",
            PlistValue::from("OTHER.com.veya.fixture"),
        ),
        ("com.apple.developer.team-identifier", "OTHER".into()),
        (
            "keychain-access-groups",
            PlistValue::Array(vec!["OTHER.group".into()]),
        ),
        (
            "keychain-access-groups",
            PlistValue::Array(vec!["TESTTEAM01.*".into()]),
        ),
        (
            "com.apple.security.application-groups",
            PlistValue::Array(vec!["group.ungranted".into()]),
        ),
        ("aps-environment", "production".into()),
        ("com.apple.private.taskport", true.into()),
    ] {
        let mut wrong = requested.clone();
        wrong.insert(key.into(), value);
        assert!(
            reconcile_profile_dictionary("com.veya.fixture", &hex_digest(cert), &p, &wrong)
                .is_err(),
            "{key}"
        );
    }
    assert!(
        reconcile_profile_dictionary("com.veya.fixture", &hex_digest(b"other"), &p, &requested)
            .is_err()
    );
}

#[test]
fn app_groups_require_exact_grants_and_expired_profiles_fail() {
    let cert = b"cert";
    let mut requested = dictionary();
    requested.insert(
        "com.apple.security.application-groups".into(),
        PlistValue::Array(vec!["group.veya".into()]),
    );
    let mut p = profile(cert, requested.clone());
    assert!(
        reconcile_profile_dictionary("com.veya.fixture", &hex_digest(cert), &p, &requested).is_ok()
    );
    requested.insert(
        "com.apple.security.application-groups".into(),
        PlistValue::Array(vec!["group.other".into()]),
    );
    assert!(
        reconcile_profile_dictionary("com.veya.fixture", &hex_digest(cert), &p, &requested)
            .is_err()
    );
    p.insert(
        "ExpirationDate".into(),
        PlistValue::Date((SystemTime::now() - Duration::from_secs(1)).into()),
    );
    assert!(
        reconcile_profile_dictionary("com.veya.fixture", &hex_digest(cert), &p, &dictionary())
            .is_err()
    );
}

#[test]
fn plaintext_and_self_signed_cms_profiles_are_rejected() {
    let (key, cert) = identity();
    let payload = b"not an Apple provisioning profile";
    let private = PKey::private_key_from_pkcs8(&key).unwrap();
    let cert = X509::from_der(&cert).unwrap();
    let cms = openssl::pkcs7::Pkcs7::sign(
        &cert,
        &private,
        &openssl::stack::Stack::new().unwrap(),
        payload,
        openssl::pkcs7::Pkcs7Flags::BINARY,
    )
    .unwrap()
    .to_der()
    .unwrap();
    assert!(decode_cms_profile(payload).is_err());
    assert!(decode_cms_profile(&cms).is_err());
}

fn identity() -> (Zeroizing<Vec<u8>>, Vec<u8>) {
    let key = PKey::from_rsa(Rsa::generate(2048).unwrap()).unwrap();
    let mut name = X509NameBuilder::new().unwrap();
    name.append_entry_by_text("CN", "Veya Synthetic Signer")
        .unwrap();
    name.append_entry_by_text("OU", "TESTTEAM01").unwrap();
    let name = name.build();
    let mut cert = X509::builder().unwrap();
    cert.set_version(2).unwrap();
    cert.set_subject_name(&name).unwrap();
    cert.set_issuer_name(&name).unwrap();
    cert.set_pubkey(&key).unwrap();
    cert.set_not_before(&Asn1Time::days_from_now(0).unwrap())
        .unwrap();
    cert.set_not_after(&Asn1Time::days_from_now(1).unwrap())
        .unwrap();
    cert.append_extension(
        openssl::x509::extension::KeyUsage::new()
            .digital_signature()
            .build()
            .unwrap(),
    )
    .unwrap();
    cert.append_extension(
        openssl::x509::extension::ExtendedKeyUsage::new()
            .code_signing()
            .build()
            .unwrap(),
    )
    .unwrap();
    cert.sign(&key, MessageDigest::sha256()).unwrap();
    (
        Zeroizing::new(key.private_key_to_pkcs8().unwrap()),
        cert.build().to_der().unwrap(),
    )
}

fn bundle(path: &Path, id: &str, dylib: bool) {
    fs::create_dir_all(path).unwrap();
    let mut info = PlistDictionary::new();
    info.insert("CFBundleIdentifier".into(), id.into());
    info.insert("CFBundleExecutable".into(), "Fixture".into());
    info.insert(
        "CFBundlePackageType".into(),
        if dylib { "FMWK" } else { "APPL" }.into(),
    );
    info.insert("CFBundleVersion".into(), "1".into());
    PlistValue::Dictionary(info)
        .to_file_xml(path.join("Info.plist"))
        .unwrap();
    let code = path.parent().unwrap().join("fixture.c");
    fs::write(&code, "int main(void) { return 0; }\n").unwrap();
    let mut cmd = Command::new("/usr/bin/xcrun");
    cmd.args([
        "--sdk",
        "iphoneos",
        "clang",
        "-target",
        "arm64-apple-ios16.0",
        "-Wl,-no_adhoc_codesign",
    ]);
    if dylib {
        cmd.arg("-dynamiclib");
    }
    let out = cmd
        .arg(&code)
        .arg("-o")
        .arg(path.join("Fixture"))
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    fs::remove_file(code).unwrap();
    fs::write(path.join("resource.txt"), "immutable").unwrap();
}

fn synthetic_decode(bytes: &[u8]) -> Result<PlistDictionary, SigningError> {
    Ok(PlistValue::from_reader(Cursor::new(bytes))?
        .into_dictionary()
        .unwrap())
}

fn request(input: &Path, output: &Path) -> SignRequest {
    let (pkcs8, cert) = identity();
    let graph = inspect_bundle(input).unwrap();
    let mut profiles = BTreeMap::new();
    let mut entitlements = BTreeMap::new();
    for id in provisioned_bundle_ids(&graph) {
        let mut ent = dictionary();
        ent.insert(
            "application-identifier".into(),
            format!("TESTTEAM01.{id}").into(),
        );
        ent.insert(
            "keychain-access-groups".into(),
            PlistValue::Array(vec![format!("TESTTEAM01.{id}").into()]),
        );
        let mut bytes = Vec::new();
        PlistValue::Dictionary(profile(&cert, ent.clone()))
            .to_writer_xml(&mut bytes)
            .unwrap();
        profiles.insert(id.clone(), bytes);
        entitlements.insert(id, ent);
    }
    SignRequest {
        input_bundle: input.to_owned(),
        output_bundle: output.to_owned(),
        pkcs8,
        certificate_chain_der: vec![cert],
        profiles,
        entitlements,
        expected: ExpectedBundleGraph::from_graph(&graph),
    }
}

#[test]
fn nested_ios_signing_independently_verifies_and_preserves_source() {
    let temp = tempfile::tempdir().unwrap();
    let input = temp.path().join("Input.app");
    let output = temp.path().join("Output.app");
    bundle(&input, "com.veya.fixture", false);
    bundle(
        &input.join("Frameworks/Fixture.framework"),
        "com.veya.framework",
        true,
    );
    bundle(
        &input.join("PlugIns/Extension.appex"),
        "com.veya.fixture.extension",
        false,
    );
    let before = inspect_bundle(&input).unwrap();
    let receipt =
        sign_with_profile_decoder(request(&input, &output), || false, synthetic_decode).unwrap();
    assert_eq!(receipt.verified_machos.len(), 3);
    assert_eq!(inspect_bundle(&input).unwrap(), before);
    assert_eq!(verify_bundle(&output).unwrap().verified_machos.len(), 3);
    // Apple tooling is used solely as an independent qualification verifier.
    let verification = Command::new("/usr/bin/codesign")
        .args(["--verify", "--deep", "--strict", "--verbose=2"])
        .arg(&output)
        .output()
        .unwrap();
    assert!(
        verification.status.success(),
        "{}",
        String::from_utf8_lossy(&verification.stderr)
    );
    fs::write(output.join("Fixture"), b"corrupt").unwrap();
    assert!(verify_bundle(&output).is_err());
}

#[test]
fn cancelled_or_failed_signing_never_publishes_candidate() {
    let temp = tempfile::tempdir().unwrap();
    let input = temp.path().join("Input.app");
    let output = temp.path().join("Output.app");
    bundle(&input, "com.veya.fixture", false);
    let before = inspect_bundle(&input).unwrap();
    let count = std::cell::Cell::new(0);
    let result = sign_with_profile_decoder(
        request(&input, &output),
        || {
            count.set(count.get() + 1);
            count.get() >= 5
        },
        synthetic_decode,
    );
    assert!(matches!(result, Err(SigningError::Cancelled)));
    assert!(!output.exists());
    assert_eq!(inspect_bundle(&input).unwrap(), before);
    assert_eq!(fs::read_dir(temp.path()).unwrap().count(), 1);
    let mut bad = request(&input, &output);
    bad.expected.inventory_sha256 = "wrong".into();
    assert!(sign_with_profile_decoder(bad, || false, synthetic_decode).is_err());
    assert!(!output.exists());
}

fn arm64_only_executable(path: &Path, dylib: bool) {
    let code = path.with_extension("c");
    fs::write(
        &code,
        "int veya_fixture(void) { return 0; }\nint main(void) { return 0; }\n",
    )
    .unwrap();
    let mut cmd = Command::new("/usr/bin/xcrun");
    cmd.args([
        "--sdk",
        "iphoneos",
        "clang",
        "-target",
        "arm64-apple-ios16.0",
        "-Wl,-no_adhoc_codesign",
    ]);
    if dylib {
        cmd.args([
            "-dynamiclib",
            "-install_name",
            "@rpath/libVeyaFixture.dylib",
        ]);
    }
    let out = cmd.arg(&code).arg("-o").arg(path).output().unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    fs::remove_file(code).unwrap();
}

fn sign_synthetic(input: &Path, output: &Path) -> Result<SigningReceipt, SigningError> {
    sign_with_profile_decoder(request(input, output), || false, synthetic_decode)
}

fn assert_apple_verifies(path: &Path) {
    let verification = Command::new("/usr/bin/codesign")
        .args(["--verify", "--deep", "--strict", "--verbose=2"])
        .arg(path)
        .output()
        .unwrap();
    assert!(
        verification.status.success(),
        "{}",
        String::from_utf8_lossy(&verification.stderr)
    );
}

/// Qualifies the exact shipped Veya iOS payload (main app + XCTest runner with
/// its `.xctest` plug-in) through the production signer with a synthetic
/// identity. Run by `veya-qualify`/M5 evidence with VEYA_EXACT_PAYLOAD_DIR set
/// to a `DeviceArtifacts` directory; ignored in plain `cargo test` because the
/// payload is a build product, not a source fixture.
#[test]
#[ignore = "requires VEYA_EXACT_PAYLOAD_DIR (DeviceArtifacts build product)"]
fn exact_veya_payload_signs_and_independently_verifies() {
    let source = PathBuf::from(
        std::env::var("VEYA_EXACT_PAYLOAD_DIR").expect("VEYA_EXACT_PAYLOAD_DIR must be set"),
    );
    let manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(source.join("manifest.json")).unwrap()).unwrap();
    let components = manifest["components"].as_array().unwrap();
    assert!(!components.is_empty());
    let temp = tempfile::tempdir().unwrap();
    for component in components {
        let relative = component["relativePath"].as_str().unwrap();
        let name = Path::new(relative).file_name().unwrap();
        let input = temp.path().join(name);
        copy_tree_safely(&source.join(name), &input).unwrap();
        let before = inspect_bundle(&input).unwrap();
        assert_eq!(
            before.root_bundle_id,
            component["bundleIdentifier"].as_str().unwrap()
        );
        let output = temp
            .path()
            .join(format!("signed-{}", name.to_string_lossy()));
        let receipt = sign_synthetic(&input, &output).unwrap();
        let machos = before
            .nodes
            .iter()
            .filter(|n| n.kind == BundleNodeKind::MachO)
            .count();
        assert_eq!(receipt.verified_machos.len(), machos, "{relative}");
        assert_eq!(inspect_bundle(&input).unwrap(), before, "source mutated");
        verify_bundle(&output).unwrap();
        assert_apple_verifies(&output);
        eprintln!(
            "EXACT_PAYLOAD_SIGNED {} machos={} output_inventory={}",
            receipt.root_bundle_id, machos, receipt.output_inventory_sha256
        );
    }
}

#[test]
fn golden_graph_with_dylib_nested_app_xctest_and_stale_resign() {
    let temp = tempfile::tempdir().unwrap();
    let input = temp.path().join("Input.app");
    bundle(&input, "com.veya.fixture", false);
    bundle(
        &input.join("Frameworks/Fixture.framework"),
        "com.veya.framework",
        true,
    );
    arm64_only_executable(&input.join("Frameworks/libVeyaFixture.dylib"), true);
    bundle(
        &input.join("PlugIns/Extension.appex"),
        "com.veya.fixture.extension",
        false,
    );
    bundle(
        &input.join("PlugIns/FixtureTests.xctest"),
        "com.veya.fixture.tests",
        true,
    );
    bundle(
        &input.join("Watch/Nested.app"),
        "com.veya.fixture.nested",
        false,
    );
    fs::create_dir_all(input.join("Assets")).unwrap();
    fs::write(input.join("Assets/data.txt"), "resource").unwrap();

    let graph = inspect_bundle(&input).unwrap();
    // Profiles/entitlements cover exactly .app/.appex bundles; frameworks,
    // dylibs and XCTest bundles receive neither.
    assert_eq!(
        provisioned_bundle_ids(&graph),
        vec![
            "com.veya.fixture",
            "com.veya.fixture.extension",
            "com.veya.fixture.nested"
        ]
    );
    let output = temp.path().join("Output.app");
    let receipt = sign_synthetic(&input, &output).unwrap();
    assert_eq!(receipt.verified_machos.len(), 6);
    assert_apple_verifies(&output);
    for unprovisioned in [
        "Frameworks/Fixture.framework",
        "PlugIns/FixtureTests.xctest",
    ] {
        assert!(
            !output
                .join(unprovisioned)
                .join("embedded.mobileprovision")
                .exists()
        );
    }

    // Re-signing an already signed candidate (stale signature input) must
    // produce a fresh, independently valid candidate.
    let resigned = temp.path().join("Resigned.app");
    sign_synthetic(&output, &resigned).unwrap();
    assert_apple_verifies(&resigned);
}

#[test]
fn malformed_macho_and_unknown_code_fail_without_publishing() {
    let temp = tempfile::tempdir().unwrap();
    let input = temp.path().join("Input.app");
    bundle(&input, "com.veya.fixture", false);
    // Mach-O magic followed by garbage: inventory classifies it as code, so
    // signing must fail rather than silently seal it as a resource.
    let mut bytes = 0xfeedfacf_u32.to_le_bytes().to_vec();
    bytes.extend_from_slice(&[0xAB; 64]);
    fs::write(input.join("Broken"), bytes).unwrap();
    fs::set_permissions(input.join("Broken"), fs::Permissions::from_mode(0o755)).unwrap();
    let before = inspect_bundle(&input).unwrap();
    let output = temp.path().join("Output.app");
    assert!(sign_synthetic(&input, &output).is_err());
    assert!(!output.exists());
    assert_eq!(inspect_bundle(&input).unwrap(), before);
    assert_eq!(fs::read_dir(temp.path()).unwrap().count(), 1);

    // Code added after manifest approval is rejected before any mutation.
    fs::remove_file(input.join("Broken")).unwrap();
    let approved = request(&input, &output);
    arm64_only_executable(&input.join("Injected"), false);
    assert!(matches!(
        sign_with_profile_decoder(approved, || false, synthetic_decode),
        Err(SigningError::InventoryMismatch(_))
    ));
    assert!(!output.exists());
}

#[test]
fn internal_symlink_is_refused_before_mutation() {
    // Regression: the pinned signer sealed symlinks as regular files, which
    // Apple verification rejects (-67054). Refuse deterministically instead.
    let temp = tempfile::tempdir().unwrap();
    let input = temp.path().join("Input.app");
    bundle(&input, "com.veya.fixture", false);
    symlink("resource.txt", input.join("alias.txt")).unwrap();
    let before = inspect_bundle(&input).unwrap();
    let output = temp.path().join("Output.app");
    let error = sign_synthetic(&input, &output).err().unwrap();
    assert!(error.to_string().contains("symlinks are not supported"));
    assert!(!output.exists());
    assert_eq!(inspect_bundle(&input).unwrap(), before);
    assert_eq!(fs::read_dir(temp.path()).unwrap().count(), 1);
}

//! The profile trust boundary uses the OS CMS implementation, independently of
//! apple-codesign. No Keychain identities, network requests, or subprocesses.
use crate::SigningError;

fn invalid() -> SigningError {
    SigningError::InvalidRequest("profile CMS signature or Apple signer trust is invalid".into())
}

#[cfg(target_os = "macos")]
pub fn verify_and_decode(encoded: &[u8]) -> Result<Vec<u8>, SigningError> {
    use apple_codesign::KnownCertificate;
    use core_foundation::{
        base::{CFType, TCFType},
        data::CFData,
    };
    use security_framework::{certificate::SecCertificate, policy::SecPolicy, trust::SecTrust};
    use security_framework_sys::cms::*;
    use std::ptr;
    if encoded.is_empty() || encoded.len() > super::MAX_PROFILE_BYTES {
        return Err(invalid());
    }
    // SAFETY: all OS out-pointers are initialized, adopted with Create ownership
    // after success, and released by RAII on every return. The message is live
    // for the complete decoder call; no pointer escapes.
    unsafe {
        let mut raw = ptr::null_mut();
        if CMSDecoderCreate(&mut raw) != 0 || raw.is_null() {
            return Err(invalid());
        }
        let _decoder = CFType::wrap_under_create_rule(raw.cast());
        if CMSDecoderUpdateMessage(raw, encoded.as_ptr().cast(), encoded.len()) != 0
            || CMSDecoderFinalizeMessage(raw) != 0
        {
            return Err(invalid());
        }
        let mut signers = 0;
        if CMSDecoderGetNumSigners(raw, &mut signers) != 0 || signers != 1 {
            return Err(invalid());
        }
        let policy = SecPolicy::create_x509();
        let mut status = CMSSignerStatus::kCMSSignerUnsigned;
        let mut raw_trust = ptr::null_mut();
        let rc = CMSDecoderCopySignerStatus(
            raw,
            0,
            policy.as_CFTypeRef(),
            0,
            &mut status,
            &mut raw_trust,
            ptr::null_mut(),
        );
        let trust = if raw_trust.is_null() {
            None
        } else {
            Some(SecTrust::wrap_under_create_rule(raw_trust))
        };
        if rc != 0 || status != CMSSignerStatus::kCMSSignerValid {
            return Err(invalid());
        }
        let mut trust = trust.ok_or_else(invalid)?;
        let roots = KnownCertificate::all_roots()
            .iter()
            .map(|cert| {
                SecCertificate::from_der(&cert.encode_der().map_err(|_| invalid())?)
                    .map_err(|_| invalid())
            })
            .collect::<Result<Vec<_>, _>>()?;
        trust
            .set_anchor_certificates(&roots)
            .map_err(|_| invalid())?;
        trust
            .set_trust_anchor_certificates_only(true)
            .map_err(|_| invalid())?;
        trust
            .set_network_fetch_allowed(false)
            .map_err(|_| invalid())?;
        trust.evaluate_with_error().map_err(|_| invalid())?;
        // Restrict purpose as well as anchor: an Apple-issued developer cert
        // must never authorize a caller-created provisioning profile.
        let mut raw_leaf = ptr::null_mut();
        if CMSDecoderCopySignerCert(raw, 0, &mut raw_leaf) != 0 || raw_leaf.is_null() {
            return Err(invalid());
        }
        let leaf = SecCertificate::wrap_under_create_rule(raw_leaf);
        let parsed = x509_certificate::CapturedX509Certificate::from_der(leaf.to_der())
            .map_err(|_| invalid())?;
        if parsed.subject_common_name().as_deref()
            != Some("Apple iPhone OS Provisioning Profile Signing")
            || parsed.issuer_common_name().as_deref()
                != Some("Apple iPhone Certification Authority")
        {
            return Err(invalid());
        }
        let mut raw_content = ptr::null();
        if CMSDecoderCopyContent(raw, &mut raw_content) != 0 || raw_content.is_null() {
            return Err(invalid());
        }
        let content = CFData::wrap_under_create_rule(raw_content);
        if content.len() > 1024 * 1024 {
            return Err(invalid());
        }
        Ok(content.bytes().to_vec())
    }
}

#[cfg(not(target_os = "macos"))]
pub fn verify_and_decode(_encoded: &[u8]) -> Result<Vec<u8>, SigningError> {
    Err(invalid())
}

//! Synchronous signer ABI. Inputs are borrowed until return; the caller owns
//! and clears the input key. Results use the existing BridgeResult allocator.
use crate::{BridgeResult, Status, make_result};
use serde::{Deserialize, Serialize};
use std::{
    cell::Cell,
    panic::{AssertUnwindSafe, catch_unwind},
    path::PathBuf,
    slice,
    sync::{
        Once,
        atomic::{AtomicBool, Ordering},
    },
};
use veya_signing_core::{
    SignRequest, SigningError, inspect_bundle, sign_and_verify_with_cancel, verify_bundle,
};
use zeroize::Zeroizing;

const MAX_JSON: usize = 32 * 1024 * 1024;
const MAX_KEY: usize = 64 * 1024;
pub struct SigningOperation {
    cancelled: AtomicBool,
    busy: AtomicBool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PathRequest {
    schema_version: u32,
    bundle_path: PathBuf,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SigningRequest {
    schema_version: u32,
    request: SignRequest,
}

fn failure(code: &'static str, status: Status) -> *mut BridgeResult {
    make_result(
        status,
        serde_json::to_vec(&serde_json::json!({"schemaVersion":1,"code":code})).unwrap_or_default(),
        code,
    )
}
fn result<T: Serialize>(value: Result<T, SigningError>) -> *mut BridgeResult {
    match value {
        Ok(value) => match serde_json::to_vec(&value) {
            Ok(bytes) if bytes.len() <= MAX_JSON => make_result(Status::Ok, bytes, "ok"),
            _ => failure("VEYA-SIGN-RESULT-LIMIT", Status::InternalError),
        },
        Err(error) => {
            let (code, status) = match error {
                SigningError::Cancelled => ("VEYA-SIGN-CANCELLED", Status::Cancelled),
                SigningError::InvalidRequest(_) => ("VEYA-SIGN-REQUEST", Status::InvalidArgument),
                SigningError::UnsafePath(_) => ("VEYA-SIGN-PATH", Status::InvalidArgument),
                SigningError::InventoryMismatch(_) => {
                    ("VEYA-SIGN-INVENTORY", Status::ProtocolError)
                }
                SigningError::Verification { .. } => ("VEYA-SIGN-VERIFY", Status::ProtocolError),
                SigningError::Io(_) => ("VEYA-SIGN-IO", Status::ProtocolError),
                SigningError::Plist(_) => ("VEYA-SIGN-PLIST", Status::InvalidArgument),
                SigningError::Signing(_) => ("VEYA-SIGN-CRYPTO", Status::ProtocolError),
            };
            failure(code, status)
        }
    }
}

thread_local! { static IN_SIGNER: Cell<bool> = const { Cell::new(false) }; }
fn protected(call: impl FnOnce() -> *mut BridgeResult) -> *mut BridgeResult {
    static HOOK: Once = Once::new();
    HOOK.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if !IN_SIGNER.with(Cell::get) {
                previous(info);
            }
        }));
    });
    let previous = IN_SIGNER.replace(true);
    let value = catch_unwind(AssertUnwindSafe(call));
    IN_SIGNER.set(previous);
    value.unwrap_or_else(|_| failure("VEYA-SIGN-PANIC", Status::InternalError))
}
unsafe fn json<T: serde::de::DeserializeOwned>(
    bytes: *const u8,
    len: usize,
) -> Result<T, SigningError> {
    if bytes.is_null() || len == 0 || len > MAX_JSON {
        return Err(SigningError::InvalidRequest("request size".into()));
    }
    // SAFETY: readable input of declared length is part of the ABI contract.
    serde_json::from_slice(unsafe { slice::from_raw_parts(bytes, len) })
        .map_err(|_| SigningError::InvalidRequest("request JSON".into()))
}
fn valid_path(path: &std::path::Path) -> bool {
    path.is_absolute()
        && path.as_os_str().len() <= 4096
        && !path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
}

#[unsafe(no_mangle)]
pub extern "C" fn veya_signing_abi_version() -> u32 {
    veya_signing_core::SIGNING_CORE_ABI_VERSION
}
#[unsafe(no_mangle)]
pub extern "C" fn veya_signing_operation_create() -> *mut SigningOperation {
    Box::into_raw(Box::new(SigningOperation {
        cancelled: AtomicBool::new(false),
        busy: AtomicBool::new(false),
    }))
}
/// # Safety
/// Operation must be live until all calls using it return. Cancellation may run concurrently.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn veya_signing_cancel(operation: *mut SigningOperation) {
    if let Some(operation) = unsafe { operation.as_ref() } {
        operation.cancelled.store(true, Ordering::Release);
    }
}
/// # Safety
/// Transfer the live operation exactly once, after all sign/cancel calls finish.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn veya_signing_operation_free(operation: *mut SigningOperation) {
    if !operation.is_null() {
        unsafe {
            drop(Box::from_raw(operation));
        }
    }
}
/// # Safety
/// JSON must be readable for len bytes until return.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn veya_signing_inspect(bytes: *const u8, len: usize) -> *mut BridgeResult {
    protected(|| {
        result((|| {
            let request: PathRequest = unsafe { json(bytes, len)? };
            if request.schema_version != 1 || !valid_path(&request.bundle_path) {
                return Err(SigningError::InvalidRequest("schema or path".into()));
            }
            inspect_bundle(request.bundle_path)
        })())
    })
}
/// # Safety
/// JSON must be readable for len bytes until return. Verification checks Mach-O
/// signatures, not device install eligibility or a trusted expected manifest.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn veya_signing_verify(bytes: *const u8, len: usize) -> *mut BridgeResult {
    protected(|| {
        result((|| {
            let request: PathRequest = unsafe { json(bytes, len)? };
            if request.schema_version != 1 || !valid_path(&request.bundle_path) {
                return Err(SigningError::InvalidRequest("schema or path".into()));
            }
            verify_bundle(request.bundle_path)
        })())
    })
}
/// # Safety
/// Operation is live and not freed concurrently. JSON and key are readable for
/// their declared lengths. Key is never returned; caller must clear its buffer
/// immediately after this synchronous call, including on failure.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn veya_signing_sign(
    operation: *mut SigningOperation,
    bytes: *const u8,
    len: usize,
    key: *const u8,
    key_len: usize,
) -> *mut BridgeResult {
    protected(|| {
        result((|| {
            let operation = unsafe { operation.as_ref() }
                .ok_or_else(|| SigningError::InvalidRequest("operation".into()))?;
            if operation.busy.swap(true, Ordering::AcqRel) {
                return Err(SigningError::InvalidRequest("operation busy".into()));
            }
            struct Busy<'a>(&'a AtomicBool);
            impl Drop for Busy<'_> {
                fn drop(&mut self) {
                    self.0.store(false, Ordering::Release);
                }
            }
            let _busy = Busy(&operation.busy);
            if operation.cancelled.load(Ordering::Acquire) {
                return Err(SigningError::Cancelled);
            }
            if key.is_null() || key_len == 0 || key_len > MAX_KEY {
                return Err(SigningError::InvalidRequest("key length".into()));
            }
            let mut request: SigningRequest = unsafe { json(bytes, len)? };
            if request.schema_version != 1
                || !valid_path(&request.request.input_bundle)
                || !valid_path(&request.request.output_bundle)
            {
                return Err(SigningError::InvalidRequest("schema or path".into()));
            }
            // Core dumps are a process-wide resource limit. Keep them disabled after
            // signing; restoring the limit could expose remnants in library memory.
            let mut limit = libc::rlimit {
                rlim_cur: 0,
                rlim_max: 0,
            };
            if unsafe { libc::getrlimit(libc::RLIMIT_CORE, &mut limit) } != 0 {
                return Err(SigningError::InvalidRequest("core dump policy".into()));
            }
            limit.rlim_cur = 0;
            if unsafe { libc::setrlimit(libc::RLIMIT_CORE, &limit) } != 0 {
                return Err(SigningError::InvalidRequest("core dump policy".into()));
            }
            request.request.pkcs8 =
                Zeroizing::new(unsafe { slice::from_raw_parts(key, key_len) }.to_vec());
            sign_and_verify_with_cancel(request.request, || {
                operation.cancelled.load(Ordering::Acquire)
            })
        })())
    })
}
/// # Safety
/// Transfer a returned BridgeResult exactly once. Null is accepted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn veya_signing_result_free(result: *mut BridgeResult) {
    unsafe {
        crate::iossim_bridge_result_free(result);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ptr;
    unsafe fn status(result: *mut BridgeResult) -> i32 {
        let value = unsafe { (*result).status };
        unsafe {
            veya_signing_result_free(result);
        }
        value
    }
    #[test]
    fn bounds_and_malformed_requests_are_rejected_without_dereference() {
        unsafe {
            assert_eq!(status(veya_signing_inspect(ptr::null(), 1)), 1);
            assert_eq!(
                status(veya_signing_inspect(ptr::dangling(), MAX_JSON + 1)),
                1
            );
            assert_eq!(status(veya_signing_verify(b"{".as_ptr(), 1)), 1);
        }
    }
    #[test]
    fn cancellation_precedes_key_access() {
        unsafe {
            let op = veya_signing_operation_create();
            veya_signing_cancel(op);
            assert_eq!(
                status(veya_signing_sign(op, ptr::null(), 0, ptr::null(), 0)),
                8
            );
            veya_signing_operation_free(op);
        }
    }
    #[test]
    fn panic_is_contained_and_payload_redacted() {
        let result = protected(|| panic!("SECRET_CANARY"));
        unsafe {
            let payload = slice::from_raw_parts((*result).payload, (*result).payload_len);
            assert!(!String::from_utf8_lossy(payload).contains("SECRET_CANARY"));
            assert_eq!(status(result), 11);
        }
    }
    #[test]
    fn inspect_actual_bundle_and_free_owned_result() {
        let temp = tempfile::tempdir().unwrap();
        std::fs::write(temp.path().join("Info.plist"), br#"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.veya.fixture</string></dict></plist>"#).unwrap();
        let request =
            serde_json::to_vec(&serde_json::json!({"schemaVersion":1,"bundlePath":temp.path()}))
                .unwrap();
        unsafe {
            let result = veya_signing_inspect(request.as_ptr(), request.len());
            assert_eq!((*result).status, 0);
            let graph: serde_json::Value = serde_json::from_slice(slice::from_raw_parts(
                (*result).payload,
                (*result).payload_len,
            ))
            .unwrap();
            assert_eq!(graph["rootBundleId"], "com.veya.fixture");
            veya_signing_result_free(result);
        }
    }
}

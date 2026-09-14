use idevice::{
    IdeviceService,
    provider::IdeviceProvider,
    services::{amfi::AmfiClient, lockdown::LockdownClient},
    usbmuxd::{Connection, UsbmuxdAddr},
};
use serde::Serialize;
use std::{
    ffi::{CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr, slice,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

const VERSION: &[u8] = b"iossim-device-bridge/0.1.0+idevice-1838db1\0";
const MAX_IDENTIFIER_BYTES: usize = 256;
const MAX_TIMEOUT_MS: u64 = 120_000;

#[repr(i32)]
#[derive(Clone, Copy)]
enum Status {
    Ok = 0,
    InvalidArgument = 1,
    Unavailable = 2,
    DeviceNotFound = 3,
    DeviceDisconnected = 4,
    DeviceLocked = 5,
    TrustRequired = 6,
    DeveloperModeRequired = 7,
    Cancelled = 8,
    TimedOut = 9,
    ProtocolError = 10,
    InternalError = 11,
}

#[repr(C)]
pub struct BridgeResult {
    status: i32,
    payload: *mut u8,
    payload_len: usize,
    diagnostic: *mut c_char,
}

#[repr(C)]
pub struct DeviceHandle {
    stable_id: String,
    usbmux_id: u32,
    connection_generation: u64,
    cancelled: Arc<AtomicBool>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceSummary {
    stable_id: String,
    usbmux_id: u32,
    connection: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceInspection {
    stable_id: String,
    usbmux_id: u32,
    connection_generation: u64,
    connection: &'static str,
    name: Option<String>,
    model: Option<String>,
    os_version: Option<String>,
    os_build: Option<String>,
    trust: &'static str,
    lock_state: &'static str,
    developer_mode: &'static str,
}

fn clean_diagnostic(value: impl AsRef<str>) -> String {
    let raw = value.as_ref();
    let lowered = raw.to_ascii_lowercase();
    if [
        "privatekey",
        "escrowbag",
        "password",
        "security-code",
        "cookie",
        "token",
    ]
    .iter()
    .any(|needle| lowered.contains(needle))
    {
        return "device service returned a redacted error".to_string();
    }
    raw.chars()
        .filter(|c| !c.is_control() || *c == ' ')
        .take(512)
        .collect()
}

fn make_result(status: Status, payload: Vec<u8>, diagnostic: impl AsRef<str>) -> *mut BridgeResult {
    let mut payload = payload.into_boxed_slice();
    let payload_len = payload.len();
    let payload_ptr = if payload_len == 0 {
        ptr::null_mut()
    } else {
        payload.as_mut_ptr()
    };
    if payload_len > 0 {
        std::mem::forget(payload);
    }
    let diagnostic = CString::new(clean_diagnostic(diagnostic))
        .unwrap_or_default()
        .into_raw();
    Box::into_raw(Box::new(BridgeResult {
        status: status as i32,
        payload: payload_ptr,
        payload_len,
        diagnostic,
    }))
}

fn json_result<T: Serialize>(value: &T) -> *mut BridgeResult {
    match serde_json::to_vec(value) {
        Ok(payload) => make_result(Status::Ok, payload, "ok"),
        Err(_) => make_result(Status::InternalError, vec![], "result serialization failed"),
    }
}

fn protected(call: impl FnOnce() -> *mut BridgeResult) -> *mut BridgeResult {
    catch_unwind(AssertUnwindSafe(call)).unwrap_or_else(|_| {
        make_result(
            Status::InternalError,
            vec![],
            "native bridge trapped an internal panic",
        )
    })
}

fn runtime() -> Result<tokio::runtime::Runtime, *mut BridgeResult> {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(2)
        .build()
        .map_err(|_| {
            make_result(
                Status::Unavailable,
                vec![],
                "native async runtime unavailable",
            )
        })
}

fn timeout_ms(value: u64) -> Result<u64, *mut BridgeResult> {
    if value == 0 || value > MAX_TIMEOUT_MS {
        Err(make_result(
            Status::InvalidArgument,
            vec![],
            "timeout is outside the supported range",
        ))
    } else {
        Ok(value)
    }
}

unsafe fn utf8_argument<'a>(ptr: *const u8, len: usize) -> Result<&'a str, *mut BridgeResult> {
    if ptr.is_null() || len == 0 || len > MAX_IDENTIFIER_BYTES {
        return Err(make_result(
            Status::InvalidArgument,
            vec![],
            "stable device identifier is invalid",
        ));
    }
    // SAFETY: caller provides a readable buffer of `len`; bounds are checked above.
    let bytes = unsafe { slice::from_raw_parts(ptr, len) };
    std::str::from_utf8(bytes).map_err(|_| {
        make_result(
            Status::InvalidArgument,
            vec![],
            "stable device identifier is not UTF-8",
        )
    })
}

async fn devices() -> Result<Vec<idevice::usbmuxd::UsbmuxdDevice>, idevice::IdeviceError> {
    let addr = UsbmuxdAddr::default();
    let mut mux = addr.connect(0x4953_0001).await?;
    mux.get_devices().await
}

fn connection_name(connection: &Connection) -> &'static str {
    match connection {
        Connection::Usb => "usb",
        Connection::Network(_) => "wireless",
        Connection::Unknown(_) => "unknown",
    }
}

fn error_result(error: &idevice::IdeviceError) -> *mut BridgeResult {
    let message = error.to_string();
    let lower = message.to_ascii_lowercase();
    let status = if lower.contains("not found") {
        Status::DeviceNotFound
    } else if lower.contains("password protected") || lower.contains("locked") {
        Status::DeviceLocked
    } else if lower.contains("pair") || lower.contains("trust") {
        Status::TrustRequired
    } else if lower.contains("disconnect") || lower.contains("broken pipe") {
        Status::DeviceDisconnected
    } else {
        Status::ProtocolError
    };
    make_result(status, vec![], message)
}

#[unsafe(no_mangle)]
pub extern "C" fn iossim_bridge_abi_version() -> u32 {
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn iossim_bridge_version() -> *const c_char {
    VERSION.as_ptr().cast()
}

#[unsafe(no_mangle)]
pub extern "C" fn iossim_bridge_list_devices(timeout: u64) -> *mut BridgeResult {
    protected(|| {
        let timeout = match timeout_ms(timeout) {
            Ok(value) => value,
            Err(result) => return result,
        };
        let runtime = match runtime() {
            Ok(value) => value,
            Err(result) => return result,
        };
        match runtime.block_on(tokio::time::timeout(
            Duration::from_millis(timeout),
            devices(),
        )) {
            Ok(Ok(devices)) => {
                let values: Vec<_> = devices
                    .into_iter()
                    .map(|device| DeviceSummary {
                        stable_id: device.udid,
                        usbmux_id: device.device_id,
                        connection: connection_name(&device.connection_type),
                    })
                    .collect();
                json_result(&values)
            }
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(Status::TimedOut, vec![], "device discovery timed out"),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_open_device(
    stable_id: *const u8,
    stable_id_len: usize,
    connection_generation: u64,
    timeout: u64,
    out_handle: *mut *mut DeviceHandle,
) -> *mut BridgeResult {
    protected(|| {
        if out_handle.is_null() {
            return make_result(Status::InvalidArgument, vec![], "output handle is null");
        }
        let timeout = match timeout_ms(timeout) {
            Ok(value) => value,
            Err(result) => return result,
        };
        // SAFETY: validated by utf8_argument and copied before returning.
        let stable_id = match unsafe { utf8_argument(stable_id, stable_id_len) } {
            Ok(value) => value.to_string(),
            Err(result) => return result,
        };
        let runtime = match runtime() {
            Ok(value) => value,
            Err(result) => return result,
        };
        let selected = match runtime.block_on(tokio::time::timeout(
            Duration::from_millis(timeout),
            devices(),
        )) {
            Ok(Ok(devices)) => devices.into_iter().find(|device| device.udid == stable_id),
            Ok(Err(error)) => return error_result(&error),
            Err(_) => return make_result(Status::TimedOut, vec![], "opening device timed out"),
        };
        let Some(selected) = selected else {
            return make_result(
                Status::DeviceNotFound,
                vec![],
                "selected device is not connected",
            );
        };
        let handle = Box::new(DeviceHandle {
            stable_id,
            usbmux_id: selected.device_id,
            connection_generation,
            cancelled: Arc::new(AtomicBool::new(false)),
        });
        // SAFETY: `out_handle` was checked non-null and ownership transfers to caller.
        unsafe {
            *out_handle = Box::into_raw(handle);
        }
        make_result(Status::Ok, vec![], "ok")
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_inspect_device(
    handle: *mut DeviceHandle,
    timeout: u64,
) -> *mut BridgeResult {
    protected(|| {
        if handle.is_null() {
            return make_result(Status::InvalidArgument, vec![], "device handle is null");
        }
        let timeout = match timeout_ms(timeout) {
            Ok(value) => value,
            Err(result) => return result,
        };
        // SAFETY: handle ownership remains with caller for this invocation.
        let handle = unsafe { &*handle };
        if handle.cancelled.load(Ordering::Acquire) {
            return make_result(Status::Cancelled, vec![], "operation cancelled");
        }
        let stable_id = handle.stable_id.clone();
        let expected_mux = handle.usbmux_id;
        let generation = handle.connection_generation;
        let cancelled = handle.cancelled.clone();
        let runtime = match runtime() {
            Ok(value) => value,
            Err(result) => return result,
        };
        let task = async move {
            let selected = devices()
                .await?
                .into_iter()
                .find(|device| device.udid == stable_id)
                .ok_or(idevice::IdeviceError::DeviceNotFound)?;
            if selected.device_id != expected_mux {
                return Err(idevice::IdeviceError::DeviceNotFound);
            }
            let connection = connection_name(&selected.connection_type);
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let mut lockdown = LockdownClient::connect(&provider).await?;
            let name = lockdown
                .get_value(Some("DeviceName"), None)
                .await
                .ok()
                .and_then(|value| value.as_string().map(ToOwned::to_owned));
            let model = lockdown
                .get_value(Some("ProductType"), None)
                .await
                .ok()
                .and_then(|value| value.as_string().map(ToOwned::to_owned));
            let os_version = lockdown
                .get_value(Some("ProductVersion"), None)
                .await
                .ok()
                .and_then(|value| value.as_string().map(ToOwned::to_owned));
            let os_build = lockdown
                .get_value(Some("BuildVersion"), None)
                .await
                .ok()
                .and_then(|value| value.as_string().map(ToOwned::to_owned));
            let mut trust = "missing";
            let mut lock_state = "unknown";
            let mut developer_mode = "unknown";
            if let Ok(pairing) = provider.get_pairing_file().await {
                match lockdown.start_session(&pairing).await {
                    Ok(_) => {
                        trust = "trusted";
                        lock_state = "unlocked";
                        match AmfiClient::connect(&provider).await {
                            Ok(mut amfi) => {
                                developer_mode =
                                    if amfi.get_developer_mode_status().await.unwrap_or(false) {
                                        "enabled"
                                    } else {
                                        "disabled"
                                    }
                            }
                            Err(_) => developer_mode = "serviceUnavailable",
                        }
                    }
                    Err(error) => {
                        let lower = error.to_string().to_ascii_lowercase();
                        if lower.contains("password") || lower.contains("locked") {
                            lock_state = "locked";
                            trust = "trusted";
                        }
                    }
                }
            }
            if cancelled.load(Ordering::Acquire) {
                return Err(idevice::IdeviceError::NotFound);
            }
            Ok(DeviceInspection {
                stable_id,
                usbmux_id: expected_mux,
                connection_generation: generation,
                connection,
                name,
                model,
                os_version,
                os_build,
                trust,
                lock_state,
                developer_mode,
            })
        };
        match runtime.block_on(tokio::time::timeout(Duration::from_millis(timeout), task)) {
            Ok(Ok(value)) => json_result(&value),
            Ok(Err(_error)) if handle.cancelled.load(Ordering::Acquire) => {
                make_result(Status::Cancelled, vec![], "operation cancelled")
            }
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(Status::TimedOut, vec![], "device inspection timed out"),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_cancel(handle: *mut DeviceHandle) {
    if !handle.is_null() {
        // SAFETY: caller owns this live handle; only the atomic flag is accessed.
        unsafe {
            (&*handle).cancelled.store(true, Ordering::Release);
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_close_device(handle: *mut DeviceHandle) {
    if !handle.is_null() {
        // SAFETY: caller transfers the handle exactly once.
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_result_free(result: *mut BridgeResult) {
    if result.is_null() {
        return;
    }
    // SAFETY: caller transfers a result created by this library exactly once.
    let result = unsafe { Box::from_raw(result) };
    if !result.payload.is_null() && result.payload_len > 0 {
        // SAFETY: payload was allocated as a boxed slice with this exact length.
        unsafe {
            drop(Vec::from_raw_parts(
                result.payload,
                result.payload_len,
                result.payload_len,
            ));
        }
    }
    if !result.diagnostic.is_null() {
        // SAFETY: diagnostic was allocated by CString::into_raw.
        unsafe {
            drop(CString::from_raw(result.diagnostic));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diagnostic_redacts_secret_field_names() {
        assert_eq!(
            clean_diagnostic("Pairing PrivateKey invalid"),
            "device service returned a redacted error"
        );
        assert_eq!(
            clean_diagnostic("device disconnected"),
            "device disconnected"
        );
    }

    #[test]
    fn invalid_timeout_is_rejected_without_transport() {
        let result = iossim_bridge_list_devices(0);
        assert!(!result.is_null());
        unsafe {
            assert_eq!((*result).status, Status::InvalidArgument as i32);
            iossim_bridge_result_free(result);
        }
    }
}

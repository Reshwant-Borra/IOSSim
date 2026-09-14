use idevice::remote_pairing::{RemotePairingLockdownService, RpPairingFile};
use idevice::{
    IdeviceService,
    provider::IdeviceProvider,
    services::{
        afc::opcode::AfcFopenMode, amfi::AmfiClient, house_arrest::HouseArrestClient,
        installation_proxy::InstallationProxyClient, lockdown::LockdownClient,
        mobile_image_mounter::ImageMounter,
    },
    usbmuxd::{Connection, UsbmuxdAddr},
    utils::installation,
};
use serde::Serialize;
use std::{
    ffi::{CString, c_char},
    future::Future,
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
const MAX_PATH_BYTES: usize = 4096;
const MAX_CONTAINER_BYTES: usize = 16 * 1_024 * 1_024;
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

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AppRecord {
    bundle_id: String,
    version: Option<String>,
    team_id: Option<String>,
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

fn block_on_timeout<F>(
    runtime: &tokio::runtime::Runtime,
    duration: Duration,
    future: F,
) -> Result<F::Output, tokio::time::error::Elapsed>
where
    F: Future,
{
    // Tokio timer futures must be created while the runtime is entered. Creating
    // `tokio::time::timeout(...)` as the argument to `Runtime::block_on` panics
    // before block_on has a chance to establish the reactor context.
    runtime.block_on(async move { tokio::time::timeout(duration, future).await })
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

unsafe fn path_argument<'a>(ptr: *const u8, len: usize) -> Result<&'a str, *mut BridgeResult> {
    if ptr.is_null() || len == 0 || len > MAX_PATH_BYTES {
        return Err(make_result(
            Status::InvalidArgument,
            vec![],
            "developer-support path is invalid",
        ));
    }
    // SAFETY: caller provides a readable buffer of `len`; bounds are checked above.
    let bytes = unsafe { slice::from_raw_parts(ptr, len) };
    let value = std::str::from_utf8(bytes).map_err(|_| {
        make_result(
            Status::InvalidArgument,
            vec![],
            "developer-support path is not UTF-8",
        )
    })?;
    if !std::path::Path::new(value).is_absolute() || value.contains("/../") {
        return Err(make_result(
            Status::InvalidArgument,
            vec![],
            "developer-support path must be absolute and normalized",
        ));
    }
    Ok(value)
}

unsafe fn bounded_utf8_argument<'a>(
    ptr: *const u8,
    len: usize,
    maximum: usize,
    label: &str,
) -> Result<&'a str, *mut BridgeResult> {
    if ptr.is_null() || len == 0 || len > maximum {
        return Err(make_result(
            Status::InvalidArgument,
            vec![],
            format!("{label} is invalid"),
        ));
    }
    // SAFETY: caller provides a readable buffer of `len`; bounds are checked above.
    let bytes = unsafe { slice::from_raw_parts(ptr, len) };
    std::str::from_utf8(bytes).map_err(|_| {
        make_result(
            Status::InvalidArgument,
            vec![],
            format!("{label} is not UTF-8"),
        )
    })
}

fn validate_bundle_id(value: &str) -> bool {
    (3..=255).contains(&value.len())
        && value.contains('.')
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-'))
}

fn validate_container_path(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 512
        && !value.starts_with('/')
        && !value.contains('\0')
        && value
            .split('/')
            .all(|component| !component.is_empty() && component != "." && component != "..")
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

async fn selected_device(
    stable_id: &str,
    expected_mux: u32,
) -> Result<idevice::usbmuxd::UsbmuxdDevice, idevice::IdeviceError> {
    let selected = devices()
        .await?
        .into_iter()
        .find(|device| device.udid == stable_id)
        .ok_or(idevice::IdeviceError::DeviceNotFound)?;
    if selected.device_id != expected_mux {
        return Err(idevice::IdeviceError::DeviceNotFound);
    }
    Ok(selected)
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
        match block_on_timeout(&runtime, Duration::from_millis(timeout), devices()) {
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
        let selected = match block_on_timeout(&runtime, Duration::from_millis(timeout), devices()) {
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
            let selected = selected_device(&stable_id, expected_mux).await?;
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
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(value)) => json_result(&value),
            Ok(Err(_error)) if handle.cancelled.load(Ordering::Acquire) => {
                make_result(Status::Cancelled, vec![], "operation cancelled")
            }
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(Status::TimedOut, vec![], "device inspection timed out"),
        }
    })
}

/// Creates and stores a legitimate RPPairing record over the already trusted
/// USB lockdown channel. The private key is returned only in the bounded
/// result buffer so the Swift layer can put it directly into Keychain.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_create_remote_pairing(
    handle: *mut DeviceHandle,
    hostname: *const u8,
    hostname_len: usize,
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
        let hostname =
            match unsafe { bounded_utf8_argument(hostname, hostname_len, 256, "hostname") } {
                Ok(value) => value.to_string(),
                Err(result) => return result,
            };
        let handle = unsafe { &*handle };
        if handle.cancelled.load(Ordering::Acquire) {
            return make_result(Status::Cancelled, vec![], "operation cancelled");
        }
        let stable_id = handle.stable_id.clone();
        let expected_mux = handle.usbmux_id;
        let runtime = match runtime() {
            Ok(value) => value,
            Err(result) => return result,
        };
        let task = async move {
            let selected = selected_device(&stable_id, expected_mux).await?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let service = RemotePairingLockdownService::connect(&provider).await?;
            let mut client = service.into_client(&hostname)?;
            let mut pairing = RpPairingFile::generate(&hostname);
            client
                .connect(&mut pairing, async || "000000".to_string())
                .await?;
            Ok::<Vec<u8>, idevice::IdeviceError>(pairing.to_bytes())
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(bytes)) => make_result(Status::Ok, bytes, "ok"),
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(
                Status::TimedOut,
                vec![],
                "remote pairing creation timed out",
            ),
        }
    })
}

/// Validates an existing RPPairing record against the selected phone. This
/// never regenerates a record; callers decide whether a targeted repair is
/// appropriate after this proof fails.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_validate_remote_pairing(
    handle: *mut DeviceHandle,
    hostname: *const u8,
    hostname_len: usize,
    pairing_bytes: *const u8,
    pairing_len: usize,
    timeout: u64,
) -> *mut BridgeResult {
    protected(|| {
        if handle.is_null() {
            return make_result(Status::InvalidArgument, vec![], "device handle is null");
        }
        if pairing_bytes.is_null() || pairing_len == 0 || pairing_len > MAX_CONTAINER_BYTES {
            return make_result(Status::InvalidArgument, vec![], "pairing record is invalid");
        }
        let timeout = match timeout_ms(timeout) {
            Ok(value) => value,
            Err(result) => return result,
        };
        let hostname =
            match unsafe { bounded_utf8_argument(hostname, hostname_len, 256, "hostname") } {
                Ok(value) => value.to_string(),
                Err(result) => return result,
            };
        let bytes = unsafe { slice::from_raw_parts(pairing_bytes, pairing_len) }.to_vec();
        let handle = unsafe { &*handle };
        if handle.cancelled.load(Ordering::Acquire) {
            return make_result(Status::Cancelled, vec![], "operation cancelled");
        }
        let stable_id = handle.stable_id.clone();
        let expected_mux = handle.usbmux_id;
        let runtime = match runtime() {
            Ok(value) => value,
            Err(result) => return result,
        };
        let task = async move {
            let mut pairing = RpPairingFile::from_bytes(&bytes)?;
            let selected = selected_device(&stable_id, expected_mux).await?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let service = RemotePairingLockdownService::connect(&provider).await?;
            let mut client = service.into_client(&hostname)?;
            client.attempt_pair_verify().await?;
            client.validate_pairing(&mut pairing).await
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(())) => make_result(Status::Ok, vec![], "ok"),
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(
                Status::TimedOut,
                vec![],
                "remote pairing validation timed out",
            ),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_developer_support_status(
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
        let stable_id = handle.stable_id.clone();
        let expected_mux = handle.usbmux_id;
        let runtime = match runtime() {
            Ok(value) => value,
            Err(result) => return result,
        };
        let task = async move {
            let selected = selected_device(&stable_id, expected_mux).await?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let mut mounter = ImageMounter::connect(&provider).await?;
            Ok(mounter.lookup_image("Personalized").await.is_ok())
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(mounted)) => json_result(&serde_json::json!({ "mounted": mounted })),
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(
                Status::TimedOut,
                vec![],
                "developer-support status timed out",
            ),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_mount_developer_support(
    handle: *mut DeviceHandle,
    image_path: *const u8,
    image_path_len: usize,
    trust_cache_path: *const u8,
    trust_cache_path_len: usize,
    build_manifest_path: *const u8,
    build_manifest_path_len: usize,
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
        // SAFETY: each path is validated and copied before use.
        let image_path = match unsafe { path_argument(image_path, image_path_len) } {
            Ok(value) => value.to_string(),
            Err(result) => return result,
        };
        let trust_path = match unsafe { path_argument(trust_cache_path, trust_cache_path_len) } {
            Ok(value) => value.to_string(),
            Err(result) => return result,
        };
        let manifest_path =
            match unsafe { path_argument(build_manifest_path, build_manifest_path_len) } {
                Ok(value) => value.to_string(),
                Err(result) => return result,
            };
        // SAFETY: handle ownership remains with caller for this invocation.
        let handle = unsafe { &*handle };
        let stable_id = handle.stable_id.clone();
        let expected_mux = handle.usbmux_id;
        let runtime = match runtime() {
            Ok(value) => value,
            Err(result) => return result,
        };
        let task = async move {
            let selected = selected_device(&stable_id, expected_mux).await?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let mut lockdown = LockdownClient::connect(&provider).await?;
            let unique_chip_id = match lockdown
                .get_value(Some("UniqueChipID"), None)
                .await?
                .as_unsigned_integer()
            {
                Some(value) => value,
                None => {
                    return Err(idevice::IdeviceError::UnexpectedResponse(
                        "UniqueChipID is not an unsigned integer".into(),
                    ));
                }
            };
            let image = tokio::fs::read(image_path).await?;
            let trust_cache = tokio::fs::read(trust_path).await?;
            let build_manifest = tokio::fs::read(manifest_path).await?;
            let mut mounter = ImageMounter::connect(&provider).await?;
            mounter
                .mount_personalized(
                    &provider,
                    image,
                    trust_cache,
                    &build_manifest,
                    None,
                    unique_chip_id,
                )
                .await
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(())) => make_result(Status::Ok, vec![], "developer support mounted"),
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(
                Status::TimedOut,
                vec![],
                "developer-support mount timed out",
            ),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_app_inventory(
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
        let stable_id = handle.stable_id.clone();
        let expected_mux = handle.usbmux_id;
        let runtime = match runtime() {
            Ok(value) => value,
            Err(result) => return result,
        };
        let task = async move {
            let selected = selected_device(&stable_id, expected_mux).await?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let mut proxy = InstallationProxyClient::connect(&provider).await?;
            let apps = proxy.get_apps(Some("User"), None).await?;
            Ok(apps
                .into_iter()
                .map(|(bundle_id, value)| {
                    let dictionary = value.as_dictionary();
                    let version = dictionary
                        .and_then(|item| item.get("CFBundleShortVersionString"))
                        .and_then(|item| item.as_string())
                        .map(ToOwned::to_owned);
                    let team_id = dictionary
                        .and_then(|item| item.get("TeamIdentifier"))
                        .and_then(|item| item.as_string())
                        .map(ToOwned::to_owned);
                    AppRecord {
                        bundle_id,
                        version,
                        team_id,
                    }
                })
                .collect::<Vec<_>>())
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(records)) => json_result(&records),
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(Status::TimedOut, vec![], "app inventory timed out"),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_install_app(
    handle: *mut DeviceHandle,
    local_path: *const u8,
    local_path_len: usize,
    upgrade: bool,
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
        // SAFETY: path is validated and copied before use.
        let local_path = match unsafe { path_argument(local_path, local_path_len) } {
            Ok(value) => value.to_string(),
            Err(result) => return result,
        };
        // SAFETY: handle ownership remains with caller for this invocation.
        let handle = unsafe { &*handle };
        let stable_id = handle.stable_id.clone();
        let expected_mux = handle.usbmux_id;
        let runtime = match runtime() {
            Ok(value) => value,
            Err(result) => return result,
        };
        let task = async move {
            let selected = selected_device(&stable_id, expected_mux).await?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            if upgrade {
                installation::upgrade_package(&provider, local_path, None).await
            } else {
                installation::install_package(&provider, local_path, None).await
            }
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(())) => make_result(Status::Ok, vec![], "application operation completed"),
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(Status::TimedOut, vec![], "application install timed out"),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_uninstall_app(
    handle: *mut DeviceHandle,
    bundle_id: *const u8,
    bundle_id_len: usize,
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
        // SAFETY: identifier is bounded and copied before use.
        let bundle_id = match unsafe {
            bounded_utf8_argument(bundle_id, bundle_id_len, 255, "bundle identifier")
        } {
            Ok(value) if validate_bundle_id(value) => value.to_string(),
            Ok(_) => {
                return make_result(
                    Status::InvalidArgument,
                    vec![],
                    "bundle identifier is invalid",
                );
            }
            Err(result) => return result,
        };
        // SAFETY: handle ownership remains with caller for this invocation.
        let handle = unsafe { &*handle };
        let stable_id = handle.stable_id.clone();
        let expected_mux = handle.usbmux_id;
        let runtime = match runtime() {
            Ok(value) => value,
            Err(result) => return result,
        };
        let task = async move {
            let selected = selected_device(&stable_id, expected_mux).await?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let mut proxy = InstallationProxyClient::connect(&provider).await?;
            proxy.uninstall(bundle_id, None).await
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(())) => make_result(Status::Ok, vec![], "application removed"),
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(Status::TimedOut, vec![], "application uninstall timed out"),
        }
    })
}

#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_container_write(
    handle: *mut DeviceHandle,
    bundle_id: *const u8,
    bundle_id_len: usize,
    relative_path: *const u8,
    relative_path_len: usize,
    bytes: *const u8,
    bytes_len: usize,
    timeout: u64,
) -> *mut BridgeResult {
    protected(|| {
        if handle.is_null() || bytes.is_null() || bytes_len > MAX_CONTAINER_BYTES {
            return make_result(
                Status::InvalidArgument,
                vec![],
                "container write arguments are invalid",
            );
        }
        let timeout = match timeout_ms(timeout) {
            Ok(value) => value,
            Err(result) => return result,
        };
        // SAFETY: string buffers are bounded and copied before use.
        let bundle_id = match unsafe {
            bounded_utf8_argument(bundle_id, bundle_id_len, 255, "bundle identifier")
        } {
            Ok(value) if validate_bundle_id(value) => value.to_string(),
            Ok(_) => {
                return make_result(
                    Status::InvalidArgument,
                    vec![],
                    "bundle identifier is invalid",
                );
            }
            Err(result) => return result,
        };
        let relative_path = match unsafe {
            bounded_utf8_argument(relative_path, relative_path_len, 512, "container path")
        } {
            Ok(value) if validate_container_path(value) => value.to_string(),
            Ok(_) => {
                return make_result(Status::InvalidArgument, vec![], "container path is unsafe");
            }
            Err(result) => return result,
        };
        // SAFETY: byte buffer is bounded and copied before asynchronous use.
        let bytes = unsafe { slice::from_raw_parts(bytes, bytes_len) }.to_vec();
        // SAFETY: handle ownership remains with caller for this invocation.
        let handle = unsafe { &*handle };
        let stable_id = handle.stable_id.clone();
        let expected_mux = handle.usbmux_id;
        let runtime = match runtime() {
            Ok(value) => value,
            Err(result) => return result,
        };
        let task = async move {
            let selected = selected_device(&stable_id, expected_mux).await?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let house = HouseArrestClient::connect(&provider).await?;
            let mut afc = house.vend_container(bundle_id).await?;
            let mut parent = String::new();
            let components: Vec<_> = relative_path.split('/').collect();
            for component in components.iter().take(components.len().saturating_sub(1)) {
                if !parent.is_empty() {
                    parent.push('/');
                }
                parent.push_str(component);
                let _ = afc.mk_dir(&parent).await;
            }
            let mut file = afc.open(relative_path, AfcFopenMode::WrOnly).await?;
            let write = file.write_entire(&bytes).await;
            let close = file.close().await;
            write.and(close)
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(())) => make_result(Status::Ok, vec![], "container write completed"),
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(Status::TimedOut, vec![], "container write timed out"),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_container_read(
    handle: *mut DeviceHandle,
    bundle_id: *const u8,
    bundle_id_len: usize,
    relative_path: *const u8,
    relative_path_len: usize,
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
        // SAFETY: string buffers are bounded and copied before use.
        let bundle_id = match unsafe {
            bounded_utf8_argument(bundle_id, bundle_id_len, 255, "bundle identifier")
        } {
            Ok(value) if validate_bundle_id(value) => value.to_string(),
            Ok(_) => {
                return make_result(
                    Status::InvalidArgument,
                    vec![],
                    "bundle identifier is invalid",
                );
            }
            Err(result) => return result,
        };
        let relative_path = match unsafe {
            bounded_utf8_argument(relative_path, relative_path_len, 512, "container path")
        } {
            Ok(value) if validate_container_path(value) => value.to_string(),
            Ok(_) => {
                return make_result(Status::InvalidArgument, vec![], "container path is unsafe");
            }
            Err(result) => return result,
        };
        // SAFETY: handle ownership remains with caller for this invocation.
        let handle = unsafe { &*handle };
        let stable_id = handle.stable_id.clone();
        let expected_mux = handle.usbmux_id;
        let runtime = match runtime() {
            Ok(value) => value,
            Err(result) => return result,
        };
        let task = async move {
            let selected = selected_device(&stable_id, expected_mux).await?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let house = HouseArrestClient::connect(&provider).await?;
            let mut afc = house.vend_container(bundle_id).await?;
            let mut file = afc.open(relative_path, AfcFopenMode::RdOnly).await?;
            let data = file.read_n(MAX_CONTAINER_BYTES + 1).await?;
            file.close().await?;
            Ok(data)
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(data)) if data.len() <= MAX_CONTAINER_BYTES => {
                make_result(Status::Ok, data, "container read completed")
            }
            Ok(Ok(_)) => make_result(
                Status::ProtocolError,
                vec![],
                "container response exceeded size limit",
            ),
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(Status::TimedOut, vec![], "container read timed out"),
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

    #[test]
    fn timeout_future_is_created_inside_runtime_context() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        let result = block_on_timeout(&runtime, Duration::from_millis(50), async { 42 });
        assert_eq!(result.expect("timer should run"), 42);
    }

    #[test]
    fn ffi_result_layout_and_payload_ownership_are_stable() {
        assert_eq!(std::mem::size_of::<BridgeResult>(), 32);
        assert_eq!(std::mem::align_of::<BridgeResult>(), 8);
        let result = json_result(&vec![DeviceSummary {
            stable_id: "00008150-00022D581E12401C".to_string(),
            usbmux_id: 42,
            connection: "usb",
        }]);
        assert!(!result.is_null());
        unsafe {
            assert_eq!((*result).status, Status::Ok as i32);
            let payload = slice::from_raw_parts((*result).payload, (*result).payload_len);
            let value: serde_json::Value =
                serde_json::from_slice(payload).expect("valid JSON payload");
            assert_eq!(value[0]["usbmuxId"], 42);
            assert_eq!(value[0]["connection"], "usb");
            iossim_bridge_result_free(result);
        }
    }

    #[test]
    fn live_list_entrypoint_returns_a_result_without_reactor_panic() {
        let result = iossim_bridge_list_devices(250);
        assert!(!result.is_null());
        unsafe { iossim_bridge_result_free(result) };
    }

    #[test]
    fn container_and_bundle_paths_are_scoped() {
        assert!(validate_bundle_id("com.example.iossim"));
        assert!(!validate_bundle_id("../bad"));
        assert!(validate_container_path(
            "Library/Application Support/IOSSim/runtime.json"
        ));
        assert!(!validate_container_path("../outside"));
        assert!(!validate_container_path("/private/var/tmp/outside"));
        assert!(!validate_container_path("Library//outside"));
    }
}

use idevice::remote_pairing::{RemotePairingLockdownService, RpPairingFile};
use idevice::{
    IdeviceService, RsdService,
    core_device::AppServiceClient,
    core_device_proxy::CoreDeviceProxy,
    provider::IdeviceProvider,
    rsd::RsdHandshake,
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
#[derive(Clone, Copy, Debug)]
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
    DeviceResolutionFailed = 12,
    CoreDeviceProxyFailed = 13,
    SoftwareTunnelFailed = 14,
    RsdUnavailable = 15,
    RemoteXpcFailed = 16,
    AppServiceUnavailable = 17,
    FeatureUnavailable = 18,
    ApplicationNotFound = 19,
    DdiRequired = 20,
    #[allow(dead_code)]
    DeveloperServicesNotReady = 21,
    LaunchRejected = 22,
    ContainerUnavailable = 23,
    PairingRejected = 24,
    PairingPending = 25,
    PairingDenied = 26,
}

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ConnectionKind {
    Unknown = 0,
    Usb = 1,
    Wireless = 2,
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
    connection: ConnectionKind,
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
struct LockdownPairingReceipt {
    schema_version: u32,
    state: &'static str,
    stable_id: String,
    usbmux_id: u32,
    connection_generation: u64,
    connection: &'static str,
    pair_record_created: bool,
    pair_record_persisted: bool,
    session_validated: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AppRecord {
    bundle_id: String,
    version: Option<String>,
    team_id: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LaunchReceipt {
    bundle_id: String,
    pid: u32,
    process_identifier_version: u32,
    app_service_connected: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DeveloperServicesReceipt {
    core_device_proxy_ready: bool,
    software_tunnel_ready: bool,
    rsd_ready: bool,
    remote_xpc_ready: bool,
    app_service_ready: bool,
    launch_feature_ready: bool,
    ddi_mounted: Option<bool>,
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

fn connection_kind(connection: &Connection) -> ConnectionKind {
    match connection {
        Connection::Usb => ConnectionKind::Usb,
        Connection::Network(_) => ConnectionKind::Wireless,
        Connection::Unknown(_) => ConnectionKind::Unknown,
    }
}

fn connection_kind_name(connection: ConnectionKind) -> &'static str {
    match connection {
        ConnectionKind::Usb => "usb",
        ConnectionKind::Wireless => "wireless",
        ConnectionKind::Unknown => "unknown",
    }
}

fn select_exact_device(
    values: Vec<idevice::usbmuxd::UsbmuxdDevice>,
    stable_id: &str,
    expected_mux: u32,
    expected_connection: ConnectionKind,
) -> Result<idevice::usbmuxd::UsbmuxdDevice, Status> {
    let matches: Vec<_> = values
        .into_iter()
        .filter(|device| device.udid == stable_id)
        .collect();
    if expected_mux == 0 || expected_connection == ConnectionKind::Unknown {
        return match matches.len() {
            0 => Err(Status::DeviceNotFound),
            1 => Ok(matches.into_iter().next().expect("one exact device")),
            _ => Err(Status::DeviceResolutionFailed),
        };
    }
    matches
        .into_iter()
        .find(|device| {
            device.device_id == expected_mux
                && connection_kind(&device.connection_type) == expected_connection
        })
        .ok_or(Status::DeviceNotFound)
}

fn error_result(error: &idevice::IdeviceError) -> *mut BridgeResult {
    let message = error.to_string();
    make_result(classify_error(error), vec![], message)
}

fn lockdown_pairing_error_result(error: &idevice::IdeviceError) -> *mut BridgeResult {
    match error {
        idevice::IdeviceError::PairingDialogResponsePending => make_result(
            Status::PairingPending,
            vec![],
            "waiting for the user to accept Trust This Computer",
        ),
        idevice::IdeviceError::UserDeniedPairing | idevice::IdeviceError::CanceledByUser => {
            make_result(
                Status::PairingDenied,
                vec![],
                "the user denied computer trust",
            )
        }
        idevice::IdeviceError::PasswordProtected | idevice::IdeviceError::DeviceLocked => {
            make_result(
                Status::DeviceLocked,
                vec![],
                "unlock the iPhone before pairing",
            )
        }
        _ => error_result(error),
    }
}

fn classify_error(error: &idevice::IdeviceError) -> Status {
    let message = error.to_string();
    let lower = message.to_ascii_lowercase();
    match error {
        idevice::IdeviceError::DeviceNotFound => Status::DeviceNotFound,
        idevice::IdeviceError::DeviceLocked => Status::DeviceLocked,
        idevice::IdeviceError::DeveloperModeNotEnabled => Status::DeveloperModeRequired,
        idevice::IdeviceError::ServiceNotFound => Status::AppServiceUnavailable,
        idevice::IdeviceError::ImageNotMounted => Status::DdiRequired,
        _ if lower.contains("password protected") || lower.contains("locked") => {
            Status::DeviceLocked
        }
        _ if lower.contains("pair") || lower.contains("trust") => Status::TrustRequired,
        _ if lower.contains("disconnect") || lower.contains("broken pipe") => {
            Status::DeviceDisconnected
        }
        _ => Status::ProtocolError,
    }
}

fn staged_error(status: Status, stage: &str, error: impl std::fmt::Display) -> *mut BridgeResult {
    make_result(status, vec![], format!("{stage}: {error}"))
}

async fn personalized_image_mounted(
    provider: &dyn IdeviceProvider,
) -> Result<bool, idevice::IdeviceError> {
    let mut mounter = ImageMounter::connect(provider).await?;
    Ok(mounter.lookup_image("Personalized").await.is_ok())
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
    2
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
    expected_usbmux_id: u32,
    expected_connection: u32,
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
        let expected_connection = match expected_connection {
            0 => ConnectionKind::Unknown,
            1 => ConnectionKind::Usb,
            2 => ConnectionKind::Wireless,
            _ => {
                return make_result(
                    Status::InvalidArgument,
                    vec![],
                    "connection kind is invalid",
                );
            }
        };
        let selected = match block_on_timeout(&runtime, Duration::from_millis(timeout), devices()) {
            Ok(Ok(devices)) => match select_exact_device(
                devices,
                &stable_id,
                expected_usbmux_id,
                expected_connection,
            ) {
                Ok(device) => Some(device),
                Err(status) => {
                    return make_result(
                        status,
                        vec![],
                        "selected device connection is missing or ambiguous",
                    );
                }
            },
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
            connection: connection_kind(&selected.connection_type),
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

/// Attempts Lockdown pairing exactly once. Apple's pending/denied/locked
/// responses are returned as typed statuses. Pairing material is persisted
/// directly through usbmuxd and never leaves this native boundary.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_pair_lockdown_once(
    handle: *mut DeviceHandle,
    host_name: *const u8,
    host_name_len: usize,
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
        let host_name =
            match unsafe { bounded_utf8_argument(host_name, host_name_len, 256, "host name") } {
                Ok(value) if !value.trim().is_empty() => value.to_string(),
                Ok(_) => return make_result(Status::InvalidArgument, vec![], "host name is empty"),
                Err(result) => return result,
            };
        let handle = unsafe { &*handle };
        if handle.cancelled.load(Ordering::Acquire) {
            return make_result(Status::Cancelled, vec![], "operation cancelled");
        }
        if handle.connection != ConnectionKind::Usb {
            return make_result(
                Status::PairingRejected,
                vec![],
                "initial computer trust requires the selected USB connection",
            );
        }
        let stable_id = handle.stable_id.clone();
        let expected_mux = handle.usbmux_id;
        let generation = handle.connection_generation;
        let connection = handle.connection;
        let cancelled = handle.cancelled.clone();
        let runtime = match runtime() {
            Ok(value) => value,
            Err(result) => return result,
        };
        let task = async move {
            let selected = selected_device(&stable_id, expected_mux).await?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let mut lockdown = LockdownClient::connect(&provider).await?;
            if let Ok(existing) = provider.get_pairing_file().await {
                if lockdown.start_session(&existing).await.is_ok() {
                    return Ok(LockdownPairingReceipt {
                        schema_version: 1,
                        state: "LOCKDOWN_SESSION_VALIDATED",
                        stable_id,
                        usbmux_id: expected_mux,
                        connection_generation: generation,
                        connection: connection_kind_name(connection),
                        pair_record_created: false,
                        pair_record_persisted: true,
                        session_validated: true,
                    });
                }
            }

            let mut mux = UsbmuxdAddr::default().connect(0x4953_0002).await?;
            let system_buid = mux.get_buid().await?;
            let mut pairing = lockdown
                .pair_once(system_buid.clone(), system_buid, Some(&host_name))
                .await?;
            pairing.udid = Some(stable_id.clone());

            // Validate the candidate before it can replace usbmuxd's stored record.
            lockdown.start_session(&pairing).await?;
            let serialized = pairing.clone().serialize()?;
            mux.save_pair_record(&stable_id, serialized).await?;

            // Re-read from the provider and validate the exact persisted record.
            let persisted = provider.get_pairing_file().await?;
            let mut validator = LockdownClient::connect(&provider).await?;
            if let Err(error) = validator.start_session(&persisted).await {
                let _ = mux.delete_pair_record(&stable_id).await;
                return Err(error);
            }
            if cancelled.load(Ordering::Acquire) {
                return Err(idevice::IdeviceError::NotFound);
            }
            Ok(LockdownPairingReceipt {
                schema_version: 1,
                state: "LOCKDOWN_SESSION_VALIDATED",
                stable_id,
                usbmux_id: expected_mux,
                connection_generation: generation,
                connection: connection_kind_name(connection),
                pair_record_created: true,
                pair_record_persisted: true,
                session_validated: true,
            })
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(receipt)) => json_result(&receipt),
            Ok(Err(_)) if handle.cancelled.load(Ordering::Acquire) => {
                make_result(Status::Cancelled, vec![], "operation cancelled")
            }
            Ok(Err(error)) => lockdown_pairing_error_result(&error),
            Err(_) => make_result(Status::TimedOut, vec![], "lockdown pairing timed out"),
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
            Ok(Err(error)) => {
                let lower = error.to_string().to_ascii_lowercase();
                if matches!(&error, idevice::IdeviceError::DeviceNotFound) {
                    error_result(&error)
                } else if matches!(&error, idevice::IdeviceError::DeviceLocked) {
                    error_result(&error)
                } else if lower.contains("trust dialog") || lower.contains("invalid host") {
                    error_result(&error)
                } else {
                    staged_error(Status::PairingRejected, "remote_pairing_validate", error)
                }
            }
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
                        .and_then(|item| {
                            item.get("CFBundleShortVersionString")
                                .or_else(|| item.get("CFBundleVersion"))
                        })
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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_developer_services_status(
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
            let selected = selected_device(&stable_id, expected_mux)
                .await
                .map_err(|error| {
                    (
                        Status::DeviceResolutionFailed,
                        "device_resolution",
                        error.to_string(),
                    )
                })?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let ddi_mounted = personalized_image_mounted(&provider).await.ok();
            let proxy = match CoreDeviceProxy::connect(&provider).await {
                Ok(value) => value,
                Err(error) => {
                    let status = if matches!(error, idevice::IdeviceError::ImageNotMounted) {
                        Status::DdiRequired
                    } else {
                        Status::CoreDeviceProxyFailed
                    };
                    return Err((status, "coredevice_proxy", error.to_string()));
                }
            };
            let rsd_port = proxy.tunnel_info().server_rsd_port;
            let adapter = proxy.create_software_tunnel().map_err(|error| {
                (
                    Status::SoftwareTunnelFailed,
                    "software_tunnel",
                    error.to_string(),
                )
            })?;
            let mut adapter = adapter.to_async_handle();
            let stream = adapter
                .connect(rsd_port)
                .await
                .map_err(|error| (Status::RsdUnavailable, "rsd_connect", error.to_string()))?;
            let mut handshake = RsdHandshake::new(stream)
                .await
                .map_err(|error| (Status::RsdUnavailable, "rsd_handshake", error.to_string()))?;
            let app_service_name = AppServiceClient::rsd_service_name();
            let Some(service) = handshake.services.get(app_service_name.as_ref()) else {
                return Err((
                    Status::AppServiceUnavailable,
                    "appservice_resolution",
                    "com.apple.coredevice.appservice is absent from the RSD service map"
                        .to_string(),
                ));
            };
            if let Some(features) = service.features.as_ref()
                && !features
                    .iter()
                    .any(|feature| feature == "com.apple.coredevice.feature.launchapplication")
            {
                return Err((
                    Status::FeatureUnavailable,
                    "appservice_feature",
                    "launchapplication is not advertised".to_string(),
                ));
            }
            let _app_service = AppServiceClient::connect_rsd(&mut adapter, &mut handshake)
                .await
                .map_err(|error| {
                    (
                        Status::RemoteXpcFailed,
                        "remotexpc_handshake",
                        error.to_string(),
                    )
                })?;
            Ok(DeveloperServicesReceipt {
                core_device_proxy_ready: true,
                software_tunnel_ready: true,
                rsd_ready: true,
                remote_xpc_ready: true,
                app_service_ready: true,
                launch_feature_ready: true,
                ddi_mounted,
            })
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(receipt)) => json_result(&receipt),
            Ok(Err((status, stage, error))) => staged_error(status, stage, error),
            Err(_) => make_result(
                Status::TimedOut,
                vec![],
                "developer_services: readiness probe timed out",
            ),
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn iossim_bridge_launch_app(
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
            let selected = selected_device(&stable_id, expected_mux)
                .await
                .map_err(|error| {
                    (
                        Status::DeviceResolutionFailed,
                        "device_resolution",
                        error.to_string(),
                    )
                })?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let proxy = match CoreDeviceProxy::connect(&provider).await {
                Ok(value) => value,
                Err(error) => {
                    let status = if matches!(error, idevice::IdeviceError::ImageNotMounted) {
                        Status::DdiRequired
                    } else {
                        Status::CoreDeviceProxyFailed
                    };
                    return Err((status, "coredevice_proxy", error.to_string()));
                }
            };
            let rsd_port = proxy.tunnel_info().server_rsd_port;
            let adapter = proxy.create_software_tunnel().map_err(|error| {
                (
                    Status::SoftwareTunnelFailed,
                    "software_tunnel",
                    error.to_string(),
                )
            })?;
            let mut adapter = adapter.to_async_handle();
            let stream = adapter
                .connect(rsd_port)
                .await
                .map_err(|error| (Status::RsdUnavailable, "rsd_connect", error.to_string()))?;
            let mut handshake = RsdHandshake::new(stream)
                .await
                .map_err(|error| (Status::RsdUnavailable, "rsd_handshake", error.to_string()))?;
            let app_service_name = AppServiceClient::rsd_service_name();
            let Some(service) = handshake.services.get(app_service_name.as_ref()) else {
                return Err((
                    Status::AppServiceUnavailable,
                    "appservice_resolution",
                    "com.apple.coredevice.appservice is absent from the RSD service map"
                        .to_string(),
                ));
            };
            if let Some(features) = service.features.as_ref()
                && !features
                    .iter()
                    .any(|feature| feature == "com.apple.coredevice.feature.launchapplication")
            {
                return Err((
                    Status::FeatureUnavailable,
                    "appservice_feature",
                    "launchapplication is not advertised".to_string(),
                ));
            }
            let mut app_service = AppServiceClient::connect_rsd(&mut adapter, &mut handshake)
                .await
                .map_err(|error| {
                    (
                        Status::RemoteXpcFailed,
                        "remotexpc_handshake",
                        error.to_string(),
                    )
                })?;
            let response = app_service
                .launch_application(bundle_id.clone(), &[], true, false, None, None, None)
                .await
                .map_err(|error| {
                    let message = error.to_string();
                    let lower = message.to_ascii_lowercase();
                    let status = if matches!(error, idevice::IdeviceError::NotFound) {
                        Status::ApplicationNotFound
                    } else if matches!(error, idevice::IdeviceError::DeviceLocked) {
                        Status::DeviceLocked
                    } else if matches!(error, idevice::IdeviceError::DeveloperModeNotEnabled) {
                        Status::DeveloperModeRequired
                    } else if lower.contains("security")
                        || lower.contains("denied")
                        || lower.contains("signature")
                        || lower.contains("trusted")
                    {
                        Status::LaunchRejected
                    } else {
                        Status::ProtocolError
                    };
                    (status, "launchapplication", message)
                })?;
            Ok(LaunchReceipt {
                bundle_id,
                pid: response.pid,
                process_identifier_version: response.process_identifier_version,
                app_service_connected: true,
            })
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(receipt)) => json_result(&receipt),
            Ok(Err((status, stage, error))) => staged_error(status, stage, error),
            Err(_) => make_result(
                Status::TimedOut,
                vec![],
                "launchapplication: operation timed out",
            ),
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
            Ok(Err(error)) => {
                let status = if matches!(error, idevice::IdeviceError::ServiceNotFound) {
                    Status::ContainerUnavailable
                } else {
                    classify_error(&error)
                };
                staged_error(status, "house_arrest_write", error)
            }
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
            Ok(Err(error)) => {
                let status = if matches!(error, idevice::IdeviceError::ServiceNotFound) {
                    Status::ContainerUnavailable
                } else {
                    classify_error(&error)
                };
                staged_error(status, "house_arrest_read", error)
            }
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

    #[test]
    fn service_not_found_is_not_reported_as_physical_device_missing() {
        assert_eq!(
            classify_error(&idevice::IdeviceError::ServiceNotFound) as i32,
            Status::AppServiceUnavailable as i32
        );
        assert_eq!(
            classify_error(&idevice::IdeviceError::DeviceNotFound) as i32,
            Status::DeviceNotFound as i32
        );
    }

    #[test]
    fn setup_status_values_remain_abi_stable() {
        assert_eq!(Status::DeveloperServicesNotReady as i32, 21);
        assert_eq!(Status::ContainerUnavailable as i32, 23);
        assert_eq!(Status::PairingPending as i32, 25);
        assert_eq!(Status::PairingDenied as i32, 26);
        assert_eq!(iossim_bridge_abi_version(), 2);
    }

    #[test]
    fn launch_receipt_identifies_exact_appservice_target() {
        let value = serde_json::to_value(LaunchReceipt {
            bundle_id: "com.example.runner".to_string(),
            pid: 42,
            process_identifier_version: 1,
            app_service_connected: true,
        })
        .expect("launch receipt JSON");
        assert_eq!(value["bundleId"], "com.example.runner");
        assert_eq!(value["pid"], 42);
        assert_eq!(value["appServiceConnected"], true);
    }

    #[test]
    fn exact_selector_uses_udid_mux_and_connection_not_input_order() {
        for values in [
            vec![
                device(
                    "PHONE-0001",
                    90,
                    Connection::Network("127.0.0.1".parse().unwrap()),
                ),
                device("PHONE-0001", 7, Connection::Usb),
            ],
            vec![
                device("PHONE-0001", 7, Connection::Usb),
                device(
                    "PHONE-0001",
                    90,
                    Connection::Network("127.0.0.1".parse().unwrap()),
                ),
            ],
        ] {
            let selected = select_exact_device(values, "PHONE-0001", 7, ConnectionKind::Usb)
                .expect("exact USB connection");
            assert_eq!(selected.device_id, 7);
            assert_eq!(
                connection_kind(&selected.connection_type),
                ConnectionKind::Usb
            );
        }
    }

    #[test]
    fn selector_rejects_ambiguous_legacy_or_wrong_connection_identity() {
        let ambiguous = vec![
            device("PHONE-0001", 7, Connection::Usb),
            device(
                "PHONE-0001",
                90,
                Connection::Network("127.0.0.1".parse().unwrap()),
            ),
        ];
        assert_eq!(
            select_exact_device(ambiguous, "PHONE-0001", 0, ConnectionKind::Unknown)
                .expect_err("ambiguous selection") as i32,
            Status::DeviceResolutionFailed as i32
        );
        let wrong = vec![device("PHONE-0001", 7, Connection::Usb)];
        assert_eq!(
            select_exact_device(wrong, "PHONE-0001", 7, ConnectionKind::Wireless)
                .expect_err("wrong connection") as i32,
            Status::DeviceNotFound as i32
        );
    }

    fn device(
        stable_id: &str,
        mux: u32,
        connection: Connection,
    ) -> idevice::usbmuxd::UsbmuxdDevice {
        idevice::usbmuxd::UsbmuxdDevice {
            connection_type: connection,
            udid: stable_id.to_string(),
            device_id: mux,
        }
    }
}

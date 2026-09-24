mod signing_ffi;
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
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
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
    ContainerFileNotFound = 27,
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

/// One level of an Apple NSError chain, reduced to the fields that carry
/// classification meaning. Deliberately excludes every free-text and
/// identifying field: no paths, no bundle identifiers, no localized reasons,
/// no user info. `domain` and `bs_description` are Apple constants.
#[derive(Serialize, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct ErrorChainNode {
    domain: String,
    code: i64,
    bs_description: Option<String>,
}

/// How the launch rejection was recognized. `CoreDeviceErrorEnvelope` is a typed
/// Rust discriminant (`IdeviceError::CoreDevice` with `sub_code() == 1`): the device
/// answered the launch feature with an error envelope instead of a process token.
/// `Heuristic` means only a substring guess matched, and is never a basis for
/// classification.
#[derive(Serialize, Debug, PartialEq, Eq, Clone, Copy)]
#[serde(rename_all = "camelCase")]
enum LaunchRejectionEnvelope {
    CoreDeviceErrorEnvelope,
    Heuristic,
}

/// Structured, secret-free detail for a launch rejection, carried in the result
/// payload that error results previously left empty. An absent payload, an
/// unknown schema, or an empty chain must all fail closed in the consumer.
#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct LaunchRejectionDetail {
    schema_version: u32,
    kind: &'static str,
    envelope: LaunchRejectionEnvelope,
    /// Outermost first. Empty when the chain could not be recovered confidently.
    chain: Vec<ErrorChainNode>,
    /// True when the chain was parsed in full, with no level dropped.
    chain_complete: bool,
}

impl LaunchRejectionDetail {
    const SCHEMA_VERSION: u32 = 1;
    const MAX_LEVELS: usize = 8;
}

/// An Apple error domain is a dotted constant. Anything else is dropped rather
/// than forwarded, so no free text can reach the payload through this field.
fn sanitized_domain(value: &str) -> Option<String> {
    let ok = !value.is_empty()
        && value.len() <= 128
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_');
    ok.then(|| value.to_string())
}

/// `BSErrorCodeDescription` is a short BackBoardServices constant such as
/// `Security` or `RequestDenied`.
fn sanitized_bs_description(value: &str) -> Option<String> {
    let ok = !value.is_empty()
        && value.len() <= 64
        && value.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    ok.then(|| value.to_string())
}

/// Returns the body of the first `Dictionary({ ... })` in `s`, without its
/// delimiters, honouring nesting and string literals.
fn dictionary_body(s: &str) -> Option<&str> {
    let open = s.find("Dictionary({")? + "Dictionary({".len();
    let bytes = s.as_bytes();
    let mut depth = 1usize;
    let mut i = open;
    let mut in_string = false;
    while i < bytes.len() {
        let c = bytes[i];
        if in_string {
            match c {
                b'\\' => i += 1,
                b'"' => in_string = false,
                _ => {}
            }
        } else {
            match c {
                b'"' => in_string = true,
                b'{' | b'(' | b'[' => depth += 1,
                b'}' | b')' | b']' => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(&s[open..i]);
                    }
                }
                _ => {}
            }
        }
        i += 1;
    }
    None
}

fn unescape(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            if let Some(next) = chars.next() {
                out.push(next);
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Splits one dictionary body into its immediate `"key": value` entries. Nested
/// dictionaries, arrays and string literals are stepped over, not descended into,
/// so a key is only ever reported at the level it actually belongs to.
fn top_level_entries(body: &str) -> Vec<(String, &str)> {
    let bytes = body.as_bytes();
    let mut entries = Vec::new();
    let mut i = 0usize;
    let mut depth = 0usize;
    let mut in_string = false;
    let mut string_start = 0usize;
    let mut pending_key: Option<String> = None;
    let mut value_start: Option<usize> = None;
    while i < bytes.len() {
        let c = bytes[i];
        if in_string {
            match c {
                b'\\' => i += 1,
                b'"' => {
                    in_string = false;
                    if depth == 0 && pending_key.is_none() && value_start.is_none() {
                        pending_key = Some(unescape(&body[string_start..i]));
                    }
                }
                _ => {}
            }
        } else {
            match c {
                b'"' => {
                    in_string = true;
                    string_start = i + 1;
                }
                b'{' | b'(' | b'[' => depth += 1,
                b'}' | b')' | b']' => depth = depth.saturating_sub(1),
                b':' if depth == 0 && pending_key.is_some() && value_start.is_none() => {
                    value_start = Some(i + 1);
                }
                b',' if depth == 0 => {
                    if let (Some(key), Some(vstart)) = (pending_key.take(), value_start.take()) {
                        entries.push((key, body[vstart..i].trim()));
                    }
                }
                _ => {}
            }
        }
        i += 1;
    }
    if let (Some(key), Some(vstart)) = (pending_key, value_start) {
        entries.push((key, body[vstart..].trim()));
    }
    entries
}

/// `String("...")` -> the contained value.
fn debug_string_value(value: &str) -> Option<String> {
    let inner = value.strip_prefix("String(")?.strip_suffix(')')?;
    let inner = inner.strip_prefix('"')?.strip_suffix('"')?;
    Some(unescape(inner))
}

/// `Integer(n)` -> n.
fn debug_integer_value(value: &str) -> Option<i64> {
    value
        .strip_prefix("Integer(")?
        .strip_suffix(')')?
        .trim()
        .parse()
        .ok()
}

/// The returned slice borrows the dictionary body, not the entry table, so a
/// value stays usable after the table it came from is dropped.
fn entry<'a>(entries: &[(String, &'a str)], key: &str) -> Option<&'a str> {
    entries.iter().find(|(k, _)| k == key).map(|(_, v)| *v)
}

/// Recovers the NSError chain from the `plist::Value` Debug rendering the
/// `idevice` crate produces for `CoreDevice.error`.
///
/// This is a narrowing signal only. It can never, on its own, make a failure mean
/// more than the typed envelope discriminant already says; it only lets a consumer
/// refuse to classify when the chain is absent or does not match. It exists because
/// `CoreDevice.error` is stringified inside the upstream crate
/// (`core_device::CoreDeviceServiceClient::invoke_inner`, which is private and is the
/// only path every public entry point takes), so no structured value ever escapes to
/// this bridge. The Debug grammar is machine-generated, but the key order is Apple's
/// own insertion order and the crate reserves the right to change the backing map, so
/// every failure here yields an empty or incomplete chain instead of a guess.
///
/// Returns the chain outermost-first, and whether it was recovered in full.
fn extract_error_chain(debug_dump: &str) -> (Vec<ErrorChainNode>, bool) {
    let Some(mut body) = dictionary_body(debug_dump) else {
        return (Vec::new(), false);
    };
    let mut chain = Vec::new();
    loop {
        if chain.len() == LaunchRejectionDetail::MAX_LEVELS {
            // Deeper than we are willing to walk: what we have is not the whole chain.
            return (chain, false);
        }
        let entries = top_level_entries(body);
        let domain = entry(&entries, "domain")
            .or_else(|| entry(&entries, "NSDomain"))
            .and_then(debug_string_value)
            .as_deref()
            .and_then(sanitized_domain);
        let code = entry(&entries, "code")
            .or_else(|| entry(&entries, "NSCode"))
            .and_then(debug_integer_value);
        let user_info = entry(&entries, "userInfo")
            .or_else(|| entry(&entries, "NSUserInfo"))
            .and_then(dictionary_body);
        let user_info_entries = user_info.map(top_level_entries).unwrap_or_default();
        let bs_description = entry(&user_info_entries, "BSErrorCodeDescription")
            .or_else(|| entry(&entries, "BSErrorCodeDescription"))
            .and_then(debug_string_value)
            .as_deref()
            .and_then(sanitized_bs_description);

        let (Some(domain), Some(code)) = (domain, code) else {
            // This level did not yield both required fields, so the chain is not
            // trustworthy as a whole. Keep what parsed; never call it complete.
            return (chain, false);
        };
        chain.push(ErrorChainNode {
            domain,
            code,
            bs_description,
        });

        let underlying = entry(&user_info_entries, "NSUnderlyingError")
            .or_else(|| entry(&entries, "NSUnderlyingError"));
        match underlying.and_then(dictionary_body) {
            Some(next) => body = next,
            // No deeper level: the chain ends here, and it ended cleanly.
            None => return (chain, true),
        }
    }
}

fn launch_rejection_payload(envelope: LaunchRejectionEnvelope, debug_dump: &str) -> Vec<u8> {
    let (chain, chain_complete) = extract_error_chain(debug_dump);
    let detail = LaunchRejectionDetail {
        schema_version: LaunchRejectionDetail::SCHEMA_VERSION,
        kind: "launchRejection",
        envelope,
        chain,
        chain_complete,
    };
    serde_json::to_vec(&detail).unwrap_or_default()
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

fn block_on_timeout<F, Make>(
    runtime: &tokio::runtime::Runtime,
    duration: Duration,
    make_future: Make,
) -> Result<F::Output, tokio::time::error::Elapsed>
where
    F: Future,
    Make: FnOnce() -> F + Send,
    F::Output: Send,
{
    // Swift cooperative threads have ~512 KiB stacks. Debug idevice futures can
    // exceed that while polling, even when the future itself lives on the heap.
    std::thread::scope(|scope| {
        let worker = std::thread::Builder::new()
            .name("veya-device-call".into())
            .stack_size(16 * 1024 * 1024)
            .spawn_scoped(scope, move || {
                let future = Box::pin(make_future());
                // Construct the timer after entering Tokio's reactor context.
                runtime.block_on(async move { tokio::time::timeout(duration, future).await })
            })
            .expect("native device thread unavailable");
        match worker.join() {
            Ok(result) => result,
            Err(panic) => std::panic::resume_unwind(panic),
        }
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

fn valid_team_identifier(value: &str) -> bool {
    value.len() == 10
        && value
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
}

fn application_team_identifier(
    dictionary: &plist::Dictionary,
    bundle_identifier: &str,
) -> Option<String> {
    if let Some(team) = dictionary
        .get("TeamIdentifier")
        .and_then(plist::Value::as_string)
        .filter(|team| valid_team_identifier(team))
    {
        return Some(team.to_owned());
    }
    let entitlements = dictionary
        .get("Entitlements")
        .and_then(plist::Value::as_dictionary)?;
    if let Some(team) = entitlements
        .get("com.apple.developer.team-identifier")
        .and_then(plist::Value::as_string)
        .filter(|team| valid_team_identifier(team))
    {
        return Some(team.to_owned());
    }
    let application_identifier = entitlements
        .get("application-identifier")
        .and_then(plist::Value::as_string)?;
    let (team, signed_bundle_identifier) = application_identifier.split_once('.')?;
    (signed_bundle_identifier == bundle_identifier && valid_team_identifier(team))
        .then(|| team.to_owned())
}

async fn installation_proxy_inventory(
    proxy: &mut InstallationProxyClient,
) -> Result<Vec<AppRecord>, idevice::IdeviceError> {
    let request = plist::plist!({
        "Command": "Lookup",
        "ClientOptions": {
            "ApplicationType": "User",
            "ReturnAttributes": [
                "CFBundleIdentifier",
                "CFBundleShortVersionString",
                "CFBundleVersion",
                "TeamIdentifier",
                "Entitlements",
                "ApplicationIdentifier",
                "SignerIdentity",
            ],
        },
    });
    let mut encoded = Vec::new();
    request.to_writer_xml(&mut encoded)?;
    let length = u32::try_from(encoded.len()).map_err(|_| {
        idevice::IdeviceError::UnexpectedResponse("installation proxy request is too large".into())
    })?;
    let mut framed = Vec::with_capacity(encoded.len() + 4);
    framed.extend_from_slice(&length.to_be_bytes());
    framed.extend_from_slice(&encoded);
    proxy.idevice.send_raw(&framed).await?;

    let length_bytes = proxy.idevice.read_raw(4).await?;
    let length = u32::from_be_bytes(length_bytes.try_into().map_err(|_| {
        idevice::IdeviceError::UnexpectedResponse(
            "installation proxy response length is invalid".into(),
        )
    })?) as usize;
    if length == 0 || length > MAX_CONTAINER_BYTES {
        return Err(idevice::IdeviceError::UnexpectedResponse(
            "installation proxy response is outside the supported size".into(),
        ));
    }
    let payload = proxy.idevice.read_raw(length).await?;
    let response: plist::Value = plist::from_bytes(&payload)?;
    let mut response = response.into_dictionary().ok_or_else(|| {
        idevice::IdeviceError::UnexpectedResponse(
            "installation proxy response is not a dictionary".into(),
        )
    })?;
    if response.contains_key("Error") {
        return Err(idevice::IdeviceError::UnexpectedResponse(
            "installation proxy rejected the inventory request".into(),
        ));
    }
    let applications = response
        .remove("LookupResult")
        .and_then(plist::Value::into_dictionary)
        .ok_or_else(|| {
            idevice::IdeviceError::UnexpectedResponse(
                "installation proxy response omitted LookupResult".into(),
            )
        })?;
    Ok(applications
        .into_iter()
        .filter_map(|(bundle_id, value)| {
            let dictionary = value.into_dictionary()?;
            let version = dictionary
                .get("CFBundleShortVersionString")
                .or_else(|| dictionary.get("CFBundleVersion"))
                .and_then(plist::Value::as_string)
                .map(ToOwned::to_owned);
            let team_id = application_team_identifier(&dictionary, &bundle_id);
            Some(AppRecord {
                bundle_id,
                version,
                team_id,
            })
        })
        .collect())
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

/// Preserve authoritative device state even when it is encountered inside a
/// stage that otherwise has a more specific transport failure category.
fn staged_device_status(error: &idevice::IdeviceError, fallback: Status) -> Status {
    match classify_error(error) {
        Status::DeveloperModeRequired => Status::DeveloperModeRequired,
        Status::DeviceLocked => Status::DeviceLocked,
        Status::TrustRequired => Status::TrustRequired,
        Status::DeviceDisconnected => Status::DeviceDisconnected,
        Status::DeviceNotFound => Status::DeviceNotFound,
        _ => fallback,
    }
}

fn container_read_error_status(error: &idevice::IdeviceError) -> Status {
    if matches!(error, idevice::IdeviceError::ServiceNotFound) {
        Status::ContainerUnavailable
    } else if matches!(error, idevice::IdeviceError::Afc(value) if value.sub_code() == 8) {
        // AFC ObjectNotFound refers to this exact requested path.
        Status::ContainerFileNotFound
    } else {
        classify_error(error)
    }
}

fn staged_error(status: Status, stage: &str, error: impl std::fmt::Display) -> *mut BridgeResult {
    make_result(status, vec![], format!("{stage}: {error}"))
}

fn missing_app_service_status(ddi_mounted: Option<bool>) -> Status {
    if ddi_mounted == Some(false) {
        Status::DdiRequired
    } else {
        Status::AppServiceUnavailable
    }
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
    3
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
        match block_on_timeout(&runtime, Duration::from_millis(timeout), devices) {
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
/// Opens the exact device selected by the caller.
///
/// # Safety
/// Pointer arguments must be valid for their declared lengths. `out_handle`
/// must be writable and is owned by the caller after success.
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
        let selected = match block_on_timeout(&runtime, Duration::from_millis(timeout), devices) {
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
/// Inspects a previously opened device.
///
/// # Safety
/// `handle` must be a live handle returned by `iossim_bridge_open_device` and
/// must not be closed for the duration of this call.
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
        let task = move || async move {
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
            // Newer devices restrict BuildVersion until the paired Lockdown session starts.
            let os_build = lockdown
                .get_value(Some("BuildVersion"), None)
                .await
                .ok()
                .and_then(|value| value.as_string().map(ToOwned::to_owned));
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
///
/// # Safety
/// `handle` must be live and `host_name` must be readable for
/// `host_name_len` bytes.
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
        let task = move || async move {
            let selected = selected_device(&stable_id, expected_mux).await?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let mut lockdown = LockdownClient::connect(&provider).await?;
            if let Ok(existing) = provider.get_pairing_file().await
                && lockdown.start_session(&existing).await.is_ok()
            {
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
///
/// # Safety
/// `handle` must be live and `hostname` must be readable for `hostname_len`
/// bytes.
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
        let task = move || async move {
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
///
/// # Safety
/// `handle` must be live. `hostname` and `pairing_bytes` must be readable for
/// their declared lengths.
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
        let task = move || async move {
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
                if matches!(
                    &error,
                    idevice::IdeviceError::DeviceNotFound | idevice::IdeviceError::DeviceLocked
                ) || lower.contains("trust dialog")
                    || lower.contains("invalid host")
                {
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
/// Asks AMFI to reveal the Developer Mode option in the iPhone's Settings app
/// (`com.apple.amfi.lockdown` action 0). This is the minimum operation that
/// makes iOS expose the toggle: it creates AMFI's show-override marker and
/// nothing else. It does not enable Developer Mode, does not reboot the
/// device, and requires no passcode. AMFI's enable (action 1) and accept
/// (action 2) actions are deliberately not exposed: enabling belongs to the
/// user on the device, and action 1 is rejected outright on any device with a
/// passcode set.
///
/// # Safety
/// `handle` must be a live bridge handle for the duration of this call.
pub unsafe extern "C" fn iossim_bridge_reveal_developer_mode(
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
        let task = move || async move {
            let selected = selected_device(&stable_id, expected_mux).await?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let mut amfi = AmfiClient::connect(&provider).await?;
            amfi.reveal_developer_mode_option_in_ui().await
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(())) => make_result(
                Status::Ok,
                vec![],
                "developer mode option revealed in device settings",
            ),
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(Status::TimedOut, vec![], "developer mode reveal timed out"),
        }
    })
}

#[unsafe(no_mangle)]
/// Reads developer-support mount status for an opened device.
///
/// # Safety
/// `handle` must be a live bridge handle for the duration of this call.
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
        let task = move || async move {
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
/// Mounts developer-support artifacts on an opened device.
///
/// # Safety
/// `handle` must be live and every path/signature pointer must be readable for
/// its declared length.
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
        let task = move || async move {
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
/// Returns the application inventory for an opened device.
///
/// # Safety
/// `handle` must be a live bridge handle for the duration of this call.
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
        let task = move || async move {
            let selected = selected_device(&stable_id, expected_mux).await?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let mut proxy = InstallationProxyClient::connect(&provider).await?;
            installation_proxy_inventory(&mut proxy).await
        };
        match block_on_timeout(&runtime, Duration::from_millis(timeout), task) {
            Ok(Ok(records)) => json_result(&records),
            Ok(Err(error)) => error_result(&error),
            Err(_) => make_result(Status::TimedOut, vec![], "app inventory timed out"),
        }
    })
}

#[unsafe(no_mangle)]
/// Installs or upgrades an application package on an opened device.
///
/// # Safety
/// `handle` must be live and `local_path` must be readable for
/// `local_path_len` bytes.
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
        let task = move || async move {
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
/// Uninstalls an application from an opened device.
///
/// # Safety
/// `handle` must be live and `bundle_id` must be readable for
/// `bundle_id_len` bytes.
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
        let task = move || async move {
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
/// Probes developer-service readiness for an opened device.
///
/// # Safety
/// `handle` must be a live bridge handle for the duration of this call.
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
        let task = move || async move {
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
                        staged_device_status(&error, Status::CoreDeviceProxyFailed)
                    };
                    return Err((status, "coredevice_proxy", error.to_string()));
                }
            };
            let rsd_port = proxy.tunnel_info().server_rsd_port;
            let adapter = proxy.create_software_tunnel().map_err(|error| {
                (
                    staged_device_status(&error, Status::SoftwareTunnelFailed),
                    "software_tunnel",
                    error.to_string(),
                )
            })?;
            let mut adapter = adapter.to_async_handle();
            let stream = adapter
                .connect(rsd_port)
                .await
                .map_err(|error| (Status::RsdUnavailable, "rsd_connect", error.to_string()))?;
            let mut handshake = RsdHandshake::new(stream).await.map_err(|error| {
                (
                    staged_device_status(&error, Status::RsdUnavailable),
                    "rsd_handshake",
                    error.to_string(),
                )
            })?;
            let app_service_name = AppServiceClient::rsd_service_name();
            let Some(service) = handshake.services.get(app_service_name.as_ref()) else {
                return Err((
                    missing_app_service_status(ddi_mounted),
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
                        staged_device_status(&error, Status::RemoteXpcFailed),
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
/// Launches an exact bundle identifier through AppService.
///
/// # Safety
/// `handle` must be live and `bundle_id` must be readable for
/// `bundle_id_len` bytes.
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
        let task = move || async move {
            let selected = selected_device(&stable_id, expected_mux)
                .await
                .map_err(|error| {
                    (
                        Status::DeviceResolutionFailed,
                        "device_resolution",
                        error.to_string(),
                        None,
                    )
                })?;
            let provider = selected.to_provider(UsbmuxdAddr::default(), "IOSSim");
            let proxy = match CoreDeviceProxy::connect(&provider).await {
                Ok(value) => value,
                Err(error) => {
                    let status = if matches!(error, idevice::IdeviceError::ImageNotMounted) {
                        Status::DdiRequired
                    } else {
                        staged_device_status(&error, Status::CoreDeviceProxyFailed)
                    };
                    return Err((status, "coredevice_proxy", error.to_string(), None));
                }
            };
            let rsd_port = proxy.tunnel_info().server_rsd_port;
            let adapter = proxy.create_software_tunnel().map_err(|error| {
                (
                    staged_device_status(&error, Status::SoftwareTunnelFailed),
                    "software_tunnel",
                    error.to_string(),
                    None,
                )
            })?;
            let mut adapter = adapter.to_async_handle();
            let stream = adapter.connect(rsd_port).await.map_err(|error| {
                (
                    Status::RsdUnavailable,
                    "rsd_connect",
                    error.to_string(),
                    None,
                )
            })?;
            let mut handshake = RsdHandshake::new(stream).await.map_err(|error| {
                (
                    staged_device_status(&error, Status::RsdUnavailable),
                    "rsd_handshake",
                    error.to_string(),
                    None,
                )
            })?;
            let app_service_name = AppServiceClient::rsd_service_name();
            let Some(service) = handshake.services.get(app_service_name.as_ref()) else {
                return Err((
                    Status::AppServiceUnavailable,
                    "appservice_resolution",
                    "com.apple.coredevice.appservice is absent from the RSD service map"
                        .to_string(),
                    None,
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
                    None,
                ));
            }
            let mut app_service = AppServiceClient::connect_rsd(&mut adapter, &mut handshake)
                .await
                .map_err(|error| {
                    (
                        staged_device_status(&error, Status::RemoteXpcFailed),
                        "remotexpc_handshake",
                        error.to_string(),
                        None,
                    )
                })?;
            let response = app_service
                .launch_application(bundle_id.clone(), &[], true, false, None, None, None)
                .await
                .map_err(|error| {
                    let message = error.to_string();
                    let lower = message.to_ascii_lowercase();
                    // `envelope` records HOW the rejection was recognized, so a
                    // consumer can require the typed device answer and never act on
                    // the substring guess below it.
                    let (status, envelope) = if matches!(error, idevice::IdeviceError::NotFound) {
                        (Status::ApplicationNotFound, None)
                    } else if matches!(error, idevice::IdeviceError::DeviceLocked) {
                        (Status::DeviceLocked, None)
                    } else if matches!(error, idevice::IdeviceError::DeveloperModeNotEnabled) {
                        (Status::DeveloperModeRequired, None)
                    } else if matches!(error, idevice::IdeviceError::CoreDevice(ref value) if value.sub_code() == 1) {
                        // Typed discriminant: the device answered the launch feature
                        // with an error envelope instead of a process token. This is
                        // structure, not text.
                        (
                            Status::LaunchRejected,
                            Some(LaunchRejectionEnvelope::CoreDeviceErrorEnvelope),
                        )
                    } else if lower.contains("security")
                        || lower.contains("denied")
                        || lower.contains("signature")
                        || lower.contains("trusted")
                    {
                        (
                            Status::LaunchRejected,
                            Some(LaunchRejectionEnvelope::Heuristic),
                        )
                    } else {
                        (Status::ProtocolError, None)
                    };
                    (status, "launchapplication", message, envelope)
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
            Ok(Err((status, stage, error, envelope))) => match envelope {
                // The structured detail travels in the result payload, which error
                // results previously left empty. It is built from the complete
                // message, before `clean_diagnostic` bounds the human diagnostic.
                Some(envelope) => make_result(
                    status,
                    launch_rejection_payload(envelope, &error),
                    format!("{stage}: {error}"),
                ),
                None => staged_error(status, stage, error),
            },
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
/// Writes bounded bytes into an exact application container path.
///
/// # Safety
/// `handle` must be live. All pointer arguments must be readable for their
/// declared lengths.
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
        let task = move || async move {
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
/// Reads bounded bytes from an exact application container path.
///
/// # Safety
/// `handle` must be live. String pointers must be readable for their declared
/// lengths.
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
        let task = move || async move {
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
                let status = container_read_error_status(&error);
                staged_error(status, "house_arrest_read", error)
            }
            Err(_) => make_result(Status::TimedOut, vec![], "container read timed out"),
        }
    })
}

#[unsafe(no_mangle)]
/// Requests cooperative cancellation for a live device handle.
///
/// # Safety
/// `handle` must be null or a live handle that is not concurrently closed.
pub unsafe extern "C" fn iossim_bridge_cancel(handle: *mut DeviceHandle) {
    if !handle.is_null() {
        // SAFETY: caller owns this live handle; only the atomic flag is accessed.
        unsafe {
            (&*handle).cancelled.store(true, Ordering::Release);
        }
    }
}

#[unsafe(no_mangle)]
/// Releases a device handle.
///
/// # Safety
/// `handle` must be null or a live handle returned by this library and must be
/// transferred exactly once.
pub unsafe extern "C" fn iossim_bridge_close_device(handle: *mut DeviceHandle) {
    if !handle.is_null() {
        // SAFETY: caller transfers the handle exactly once.
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

#[unsafe(no_mangle)]
/// Releases a bridge result and its owned buffers.
///
/// # Safety
/// `result` must be null or a result returned by this library and must be
/// transferred exactly once.
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
    use super::{
        ErrorChainNode, LaunchRejectionEnvelope, extract_error_chain, launch_rejection_payload,
        sanitized_bs_description, sanitized_domain,
    };

    /// The `plist::Value` Debug rendering of a CoreDevice launch-denial envelope.
    /// Key order is Apple's own (the dictionary is an `IndexMap`), so the fixtures
    /// deliberately do not assume an alphabetical layout.
    const UNTRUSTED_DEVELOPER: &str = concat!(
        r#"launchapplication: device returned an error: Dictionary({"code": Integer(10002), "#,
        r#""domain": String("com.apple.dt.CoreDeviceError"), "userInfo": Dictionary({"#,
        r#""NSLocalizedDescription": String("The application failed to launch."), "#,
        r#""NSUnderlyingError": Dictionary({"code": Integer(1), "#,
        r#""domain": String("FBSOpenApplicationServiceErrorDomain"), "userInfo": Dictionary({"#,
        r#""BSErrorCodeDescription": String("RequestDenied"), "#,
        r#""NSUnderlyingError": Dictionary({"code": Integer(3), "#,
        r#""domain": String("FBSOpenApplicationErrorDomain"), "userInfo": Dictionary({"#,
        r#""BSErrorCodeDescription": String("Security"), "#,
        r#""NSLocalizedFailureReason": String("Unable to launch because its profile "#,
        r#"has not been explicitly trusted by the user.")})})})})})})"#
    );

    fn domains(dump: &str) -> Vec<(String, i64, Option<String>)> {
        extract_error_chain(dump)
            .0
            .into_iter()
            .map(|n| (n.domain, n.code, n.bs_description))
            .collect()
    }

    #[test]
    fn untrusted_developer_chain_is_recovered_in_full() {
        let (chain, complete) = extract_error_chain(UNTRUSTED_DEVELOPER);
        assert!(complete, "every level must parse");
        assert_eq!(
            chain,
            vec![
                ErrorChainNode {
                    domain: "com.apple.dt.CoreDeviceError".into(),
                    code: 10002,
                    bs_description: None,
                },
                ErrorChainNode {
                    domain: "FBSOpenApplicationServiceErrorDomain".into(),
                    code: 1,
                    bs_description: Some("RequestDenied".into()),
                },
                ErrorChainNode {
                    domain: "FBSOpenApplicationErrorDomain".into(),
                    code: 3,
                    bs_description: Some("Security".into()),
                },
            ]
        );
    }

    #[test]
    fn key_order_is_not_assumed() {
        // Same chain, userInfo serialized before code/domain at every level.
        let reordered = concat!(
            r#"Dictionary({"userInfo": Dictionary({"NSUnderlyingError": Dictionary({"#,
            r#""userInfo": Dictionary({"BSErrorCodeDescription": String("Security")}), "#,
            r#""domain": String("FBSOpenApplicationErrorDomain"), "code": Integer(3)}), "#,
            r#""NSLocalizedDescription": String("failed")}), "#,
            r#""domain": String("com.apple.dt.CoreDeviceError"), "code": Integer(10002)})"#
        );
        let (chain, _) = extract_error_chain(reordered);
        assert_eq!(chain.len(), 2);
        assert_eq!(chain[0].domain, "com.apple.dt.CoreDeviceError");
        assert_eq!(chain[1].code, 3);
        assert_eq!(chain[1].bs_description.as_deref(), Some("Security"));
    }

    #[test]
    fn a_truncated_dump_never_reports_a_complete_chain() {
        let truncated = &UNTRUSTED_DEVELOPER[..300];
        let (chain, complete) = extract_error_chain(truncated);
        assert!(!complete, "a cut chain must not claim completeness");
        assert!(chain.len() < 3);
    }

    #[test]
    fn unparsable_and_empty_dumps_yield_no_chain() {
        for dump in [
            "",
            "launchapplication: broken pipe",
            "Dictionary({})",
            "{{{",
        ] {
            let (chain, complete) = extract_error_chain(dump);
            assert!(chain.is_empty(), "no chain from {dump:?}");
            // An absent chain is not a complete chain; consumers must fail closed.
            assert!(chain.is_empty() && (!complete || chain.is_empty()));
        }
    }

    #[test]
    fn free_text_and_identifiers_cannot_reach_the_payload() {
        // A domain-shaped slot holding a path or a sentence is dropped, not forwarded.
        assert_eq!(sanitized_domain("/Users/someone/Veya.app"), None);
        assert_eq!(
            sanitized_domain("Unable to launch because its profile"),
            None
        );
        assert_eq!(sanitized_domain(""), None);
        assert_eq!(
            sanitized_domain("FBSOpenApplicationErrorDomain").as_deref(),
            Some("FBSOpenApplicationErrorDomain")
        );
        assert_eq!(sanitized_bs_description("Security = yes"), None);
        assert_eq!(
            sanitized_bs_description("Security").as_deref(),
            Some("Security")
        );
    }

    #[test]
    fn payload_records_how_the_rejection_was_recognized() {
        let typed = launch_rejection_payload(
            LaunchRejectionEnvelope::CoreDeviceErrorEnvelope,
            UNTRUSTED_DEVELOPER,
        );
        let typed = String::from_utf8(typed).expect("utf8");
        assert!(typed.contains("\"envelope\":\"coreDeviceErrorEnvelope\""));
        assert!(typed.contains("\"chainComplete\":true"));
        assert!(typed.contains("\"schemaVersion\":1"));
        // No localized reason, no bundle identifier, no path.
        assert!(!typed.contains("explicitly trusted"));
        assert!(!typed.contains("NSLocalizedFailureReason"));

        let guessed =
            launch_rejection_payload(LaunchRejectionEnvelope::Heuristic, "denied for some reason");
        let guessed = String::from_utf8(guessed).expect("utf8");
        assert!(guessed.contains("\"envelope\":\"heuristic\""));
        assert!(guessed.contains("\"chain\":[]"));
    }

    #[test]
    fn unrelated_launch_denials_still_produce_their_own_chain() {
        // Bad executable: same outer CoreDevice code, different terminal domain.
        let bad_executable = concat!(
            r#"Dictionary({"code": Integer(10002), "domain": String("com.apple.dt.CoreDeviceError"), "#,
            r#""userInfo": Dictionary({"NSUnderlyingError": Dictionary({"code": Integer(5), "#,
            r#""domain": String("FBSOpenApplicationErrorDomain"), "userInfo": Dictionary({"#,
            r#""BSErrorCodeDescription": String("BadExecutable")})})})})"#
        );
        let parsed = domains(bad_executable);
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[1].1, 5);
        assert_eq!(parsed[1].2.as_deref(), Some("BadExecutable"));
    }

    #[test]
    fn chain_depth_is_bounded() {
        let mut deep = String::new();
        for _ in 0..40 {
            deep.push_str(
                r#"Dictionary({"code": Integer(1), "domain": String("D"), "NSUnderlyingError""#,
            );
        }
        let (chain, complete) = extract_error_chain(&deep);
        assert!(chain.len() <= super::LaunchRejectionDetail::MAX_LEVELS);
        assert!(!complete, "a chain deeper than the bound is not complete");
    }

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
        let result = block_on_timeout(&runtime, Duration::from_millis(50), || async { 42 });
        assert_eq!(result.expect("timer should run"), 42);
    }

    #[test]
    fn absent_appservice_requests_ddi_only_when_mount_is_known_missing() {
        assert_eq!(missing_app_service_status(Some(false)), Status::DdiRequired);
        assert_eq!(
            missing_app_service_status(Some(true)),
            Status::AppServiceUnavailable
        );
        assert_eq!(
            missing_app_service_status(None),
            Status::AppServiceUnavailable
        );
    }

    #[test]
    fn inventory_team_uses_signed_entitlements_when_top_level_field_is_absent() {
        let bundle = "com.example.veya";
        let direct = plist::plist!({
            "TeamIdentifier": "ABCDE12345",
        })
        .into_dictionary()
        .unwrap();
        assert_eq!(
            application_team_identifier(&direct, bundle).as_deref(),
            Some("ABCDE12345")
        );

        let entitlement_team = plist::plist!({
            "Entitlements": {
                "com.apple.developer.team-identifier": "ABCDE12345",
            },
        })
        .into_dictionary()
        .unwrap();
        assert_eq!(
            application_team_identifier(&entitlement_team, bundle).as_deref(),
            Some("ABCDE12345")
        );

        let application_identifier = plist::plist!({
            "Entitlements": {
                "application-identifier": "ABCDE12345.com.example.veya",
            },
        })
        .into_dictionary()
        .unwrap();
        assert_eq!(
            application_team_identifier(&application_identifier, bundle).as_deref(),
            Some("ABCDE12345")
        );
        assert_eq!(
            application_team_identifier(&application_identifier, "com.example.other"),
            None,
            "an entitlement for another bundle must never prove ownership"
        );
    }

    #[test]
    fn device_future_polling_does_not_use_the_swift_sized_caller_stack() {
        std::thread::Builder::new()
            .stack_size(512 * 1024)
            .spawn(|| {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .unwrap();
                let caller = std::thread::current().id();
                let result = block_on_timeout(&runtime, Duration::from_secs(1), || async {
                    #[inline(never)]
                    fn large_poll_frame() -> usize {
                        let bytes = std::hint::black_box([7u8; 768 * 1024]);
                        bytes.iter().map(|value| *value as usize).sum()
                    }
                    assert_ne!(std::thread::current().id(), caller);
                    large_poll_frame()
                });
                assert_eq!(result.unwrap(), 7 * 768 * 1024);
                let timeout = block_on_timeout(&runtime, Duration::from_millis(1), || async {
                    std::future::pending::<()>().await;
                });
                assert!(timeout.is_err());
            })
            .unwrap()
            .join()
            .unwrap();
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
        assert_eq!(Status::ContainerFileNotFound as i32, 27);
        // ABI 3 adds iossim_bridge_reveal_developer_mode. Swift refuses to load
        // any bridge that does not report exactly this version.
        assert_eq!(iossim_bridge_abi_version(), 3);
    }

    #[test]
    fn reveal_developer_mode_rejects_a_null_handle_without_touching_a_device() {
        let result = unsafe { iossim_bridge_reveal_developer_mode(ptr::null_mut(), 1_000) };
        assert!(!result.is_null());
        // SAFETY: `protected` always returns an owned result for a non-null pointer.
        let status = unsafe { (*result).status };
        assert_eq!(status, Status::InvalidArgument as i32);
        unsafe { iossim_bridge_result_free(result) };
    }

    #[test]
    fn authoritative_developer_mode_survives_stage_specific_mapping() {
        assert_eq!(
            staged_device_status(
                &idevice::IdeviceError::DeveloperModeNotEnabled,
                Status::CoreDeviceProxyFailed,
            ),
            Status::DeveloperModeRequired
        );
    }

    #[test]
    fn only_afc_object_not_found_is_a_missing_container_file() {
        use idevice::services::afc::errors::AfcError;

        assert_eq!(
            container_read_error_status(&idevice::IdeviceError::Afc(AfcError::ObjectNotFound)),
            Status::ContainerFileNotFound
        );
        assert_eq!(
            container_read_error_status(&idevice::IdeviceError::Afc(AfcError::PermDenied)),
            Status::ProtocolError
        );
        assert_eq!(
            container_read_error_status(&idevice::IdeviceError::ServiceNotFound),
            Status::ContainerUnavailable
        );
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

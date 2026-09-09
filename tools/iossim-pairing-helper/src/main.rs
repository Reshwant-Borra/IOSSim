use idevice::{
    IdeviceService,
    remote_pairing::{RemotePairingLockdownService, RpPairingFile},
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection},
};
use serde_json::json;
use std::{
    fs::OpenOptions,
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};

const LABEL: &str = "IOSSimPairingHelper";
const DEFAULT_PIN: &str = "000000";

struct Arguments {
    udid: String,
    hostname: String,
    output: PathBuf,
}

#[tokio::main]
async fn main() {
    match parse_arguments() {
        Ok(arguments) => match create_pairing(arguments).await {
            Ok(()) => {
                println!("{}", json!({"schemaVersion": 1, "state": "PAIRING_READY"}));
            }
            Err((code, message)) => {
                eprintln!("{code}: {message}");
                std::process::exit(1);
            }
        },
        Err((code, message)) => {
            eprintln!("{code}: {message}");
            std::process::exit(64);
        }
    }
}

fn parse_arguments() -> Result<Arguments, (&'static str, &'static str)> {
    let mut values = std::env::args().skip(1);
    if values.next().as_deref() != Some("create") {
        return Err(("INVALID_ARGUMENTS", "Expected create operation."));
    }
    let mut udid = None;
    let mut hostname = None;
    let mut output = None;
    while let Some(flag) = values.next() {
        let value = values
            .next()
            .ok_or(("INVALID_ARGUMENTS", "An option is missing its value."))?;
        match flag.as_str() {
            "--udid" => udid = Some(value),
            "--hostname" => hostname = Some(value),
            "--output" => output = Some(PathBuf::from(value)),
            _ => return Err(("INVALID_ARGUMENTS", "An unknown option was supplied.")),
        }
    }
    Ok(Arguments {
        udid: udid.ok_or((
            "INVALID_ARGUMENTS",
            "The selected device identifier is required.",
        ))?,
        hostname: hostname.ok_or(("INVALID_ARGUMENTS", "The host name is required."))?,
        output: output.ok_or(("INVALID_ARGUMENTS", "The output path is required."))?,
    })
}

async fn create_pairing(arguments: Arguments) -> Result<(), (&'static str, &'static str)> {
    reject_unsafe_output(&arguments.output)?;
    let address = UsbmuxdAddr::default();
    let mut usbmuxd = UsbmuxdConnection::default().await.map_err(|_| {
        (
            "USB_CONNECTION_FAILED",
            "Could not communicate with Apple's USB device service.",
        )
    })?;
    let device = usbmuxd.get_device(&arguments.udid).await.map_err(|_| {
        (
            "SELECTED_DEVICE_NOT_FOUND",
            "The selected iPhone is not connected.",
        )
    })?;
    if !matches!(device.connection_type, Connection::Usb) {
        return Err((
            "USB_CONNECTION_REQUIRED",
            "Connect the selected iPhone with a USB cable.",
        ));
    }
    let provider = device.to_provider(address, LABEL);

    let service = RemotePairingLockdownService::connect(&provider)
        .await
        .map_err(|_| {
            (
                "COMPUTER_TRUST_REQUIRED",
                "Unlock the selected iPhone and approve Apple's Trust prompt.",
            )
        })?;
    let mut client = service.into_client(&arguments.hostname).map_err(|_| {
        (
            "PAIRING_GENERATION_FAILED",
            "Could not start secure pairing.",
        )
    })?;
    let mut pairing = RpPairingFile::generate(&arguments.hostname);
    client
        .connect(&mut pairing, || async { DEFAULT_PIN.to_string() })
        .await
        .map_err(|_| {
            (
                "PAIRING_GENERATION_FAILED",
                "The selected iPhone did not complete secure pairing.",
            )
        })?;

    // Validate on a fresh connection to the exact USB-selected device before
    // any secret leaves this helper's protected staging directory.
    let validation_service = RemotePairingLockdownService::connect(&provider)
        .await
        .map_err(|_| {
            (
                "PAIRING_VALIDATION_FAILED",
                "Could not reconnect to validate pairing.",
            )
        })?;
    let mut validation_client = validation_service
        .into_client(&arguments.hostname)
        .map_err(|_| {
            (
                "PAIRING_VALIDATION_FAILED",
                "Could not start pairing validation.",
            )
        })?;
    validation_client.attempt_pair_verify().await.map_err(|_| {
        (
            "PAIRING_VALIDATION_FAILED",
            "The candidate was rejected by the selected iPhone.",
        )
    })?;
    validation_client
        .validate_pairing(&mut pairing)
        .await
        .map_err(|_| {
            (
                "PAIRING_VALIDATION_FAILED",
                "The candidate was rejected by the selected iPhone.",
            )
        })?;

    write_private_file(&arguments.output, &pairing.to_bytes()).map_err(|_| {
        (
            "PAIRING_WRITE_FAILED",
            "Could not securely stage the pairing candidate.",
        )
    })?;
    Ok(())
}

fn reject_unsafe_output(path: &Path) -> Result<(), (&'static str, &'static str)> {
    if path.exists() || !path.is_absolute() {
        return Err((
            "UNSAFE_OUTPUT_PATH",
            "The output must be a new absolute path.",
        ));
    }
    let parent = path
        .parent()
        .ok_or(("UNSAFE_OUTPUT_PATH", "The output has no parent directory."))?;
    let metadata = parent.metadata().map_err(|_| {
        (
            "UNSAFE_OUTPUT_PATH",
            "The protected staging directory is unavailable.",
        )
    })?;
    use std::os::unix::fs::MetadataExt;
    if metadata.mode() & 0o077 != 0 {
        return Err((
            "UNSAFE_OUTPUT_PATH",
            "The staging directory must be private to the current user.",
        ));
    }
    Ok(())
}

fn write_private_file(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

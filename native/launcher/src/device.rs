//! One connection to the phone's developer services: the in-process tunnel and its RSD handshake,
//! opened either through remote pairing (port 49152, an RPPairing file) or through lockdown (port
//! 62078, a lockdown pairing plist, then CoreDeviceProxy). The pairing file decides which.

use crate::remote;
use idevice::{
    IdeviceService, RsdService,
    core_device_proxy::CoreDeviceProxy,
    installation_proxy::InstallationProxyClient,
    lockdown::LockdownClient,
    pairing_file::PairingFile,
    provider::TcpProvider,
    remote_pairing::RpPairingFile,
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
};
use std::{net::IpAddr, path::Path, time::Duration};

pub type Result<T> = std::result::Result<T, Failure>;

/// A step that failed, with what the person can do about it on the phone.
#[derive(Debug, Clone)]
pub struct Failure {
    pub detail: String,
    pub fix: Option<String>,
    /// A short code the app acts on instead of the fix's words (for example `ddi_bad`: delete the
    /// image and download it again; `pairing`: the phone refused the pairing).
    pub code: Option<&'static str>,
}

impl Failure {
    pub fn new(detail: impl Into<String>) -> Self {
        Self { detail: detail.into(), fix: None, code: None }
    }
    pub fn code(mut self, code: &'static str) -> Self {
        self.code = Some(code);
        self
    }
    pub fn fix(mut self, fix: impl Into<String>) -> Self {
        self.fix = Some(fix.into());
        self
    }
}

impl<E: std::error::Error> From<E> for Failure {
    fn from(error: E) -> Self {
        Self::new(error.to_string())
    }
}

pub const LOOPBACK_FIX: &str = "Turn on the loopback in your proxy app: the Poki module in Surge or Loon, loopback_address in sing-box, or Shadowrocket's Settings → Other → \"Include route 10.7.0.1/32\". Then connect to Wi-Fi.";
pub const NETWORK_FIX: &str = "Poki needs the internet once after each restart of the phone to get Apple's signature for the developer disk image. Check Wi-Fi or cellular; Poki tries again by itself.";
pub const DDI_TIMEOUT_FIX: &str = "Mounting the developer disk image timed out. Poki needs the internet once after each restart to get Apple's signature; check Wi-Fi or cellular. Poki tries again by itself.";
pub const DDI_REFUSED_FIX: &str = "This iOS version needs a newer developer disk image. Open Poki's setup to download the latest image, or update Poki.";
pub const DDI_BAD_FIX: &str = "The developer disk image did not install. Poki downloads it again by itself.";
pub const PAIRING_FIX: &str = "Pair again in Poki's setup.";
/// The loopback took the connection, then the phone's remote pairing service did not answer, before
/// the pairing was checked. Seen with Developer Mode on (GitHub issue 69): the loopback, or a new
/// pairing made over it, is the fix.
pub const HANDSHAKE_FIX: &str = "Open Setup › Loopback and check the loopback, then pair this iPhone again in Setup › Pairing with the loopback on.";
/// After pair-verify, the listener, the tunnel or the RSD handshake failed. Nothing said why, so the
/// checks go in order, most likely first; Developer Mode only after the loopback and the pairing.
pub const UNREACHABLE_FIX: &str = "Poki can't reach this iPhone. Check in this order: Setup › Loopback (your proxy app or LocalDevVPN is connected, with 10.7.0.1 set), then Setup › Pairing (pair again with the loopback on), then Developer Mode in Settings → Privacy & Security.";
/// Only when the phone said Developer Mode is off.
pub const DEVELOPER_MODE_FIX: &str = "Turn on Developer Mode: Settings → Privacy & Security → Developer Mode, then restart the phone.";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairingKind {
    Remote,
    Lockdown,
}

impl PairingKind {
    pub fn name(self) -> &'static str {
        match self {
            Self::Remote => "remote",
            Self::Lockdown => "lockdown",
        }
    }
}

pub enum Pairing {
    Remote { file: RpPairingFile, host_name: String },
    Lockdown(PairingFile),
}

impl Pairing {
    pub fn kind(&self) -> PairingKind {
        match self {
            Self::Remote { .. } => PairingKind::Remote,
            Self::Lockdown(_) => PairingKind::Lockdown,
        }
    }

    /// Reads a pairing file of either kind: an RPPairing file (public_key, private_key, identifier)
    /// or a lockdown pairing plist (HostID, certificates, keys).
    pub fn read(path: &Path, host_name: Option<&str>) -> Result<Self> {
        let bytes = std::fs::read(path).map_err(|e| Failure::new(format!("cannot read the pairing file: {e}")).fix(PAIRING_FIX).code("pairing"))?;
        if let Ok(file) = RpPairingFile::from_bytes(&bytes) {
            let name = remote::sending_host(&bytes).or_else(|| host_name.map(String::from)).unwrap_or_else(|| "Poki".into());
            return Ok(Self::Remote { file, host_name: name });
        }
        match PairingFile::from_bytes(&bytes) {
            Ok(file) => Ok(Self::Lockdown(file)),
            Err(e) => Err(Failure::new(format!("the pairing file is neither a remote pairing file nor a lockdown pairing record ({e})")).fix(PAIRING_FIX).code("pairing")),
        }
    }
}

/// What a failed remote pairing connection tells the owner to do.
pub(crate) fn remote_failure(error: remote::RemoteError) -> Failure {
    let (fix, code) = match error.stage {
        remote::Stage::Connect => (LOOPBACK_FIX, "loopback"),
        remote::Stage::Handshake => (HANDSHAKE_FIX, "handshake"),
        remote::Stage::PairVerify => (PAIRING_FIX, "pairing"),
        remote::Stage::Listener | remote::Stage::Tunnel | remote::Stage::Rsd => (UNREACHABLE_FIX, "unreachable"),
    };
    Failure::new(error.to_string()).fix(fix).code(code)
}

/// An open tunnel. Dropping it closes everything that runs through it, the runner's session included.
pub struct Device {
    pub adapter: AdapterHandle,
    pub rsd: RsdHandshake,
    _control: Option<remote::Control>,
}

impl Device {
    /// Exercise the on-device native implementation from the physically connected Mac.
    /// Pairing stays in usbmuxd; no exported pairing record or relay is required.
    #[cfg(target_os = "macos")]
    pub async fn open_usb(udid: &str) -> Result<Self> {
        use idevice::usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection};
        let mut mux = UsbmuxdConnection::default().await?;
        let device = mux.get_devices().await?.into_iter()
            .find(|d| d.udid == udid && d.connection_type == Connection::Usb)
            .ok_or_else(|| Failure::new("No locally attached USB device matches this identifier"))?;
        let provider = device.to_provider(UsbmuxdAddr::from_env_var()?, "poki-native-usb");
        let proxy = CoreDeviceProxy::connect(&provider).await?;
        let port = proxy.tunnel_info().server_rsd_port;
        let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
        let rsd = RsdHandshake::new(adapter.connect(port).await?).await?;
        Ok(Self { adapter, rsd, _control: None })
    }

    pub async fn open(address: IpAddr, pairing: &mut Pairing, timeout: Duration) -> Result<Self> {
        match tokio::time::timeout(timeout, Self::open_inner(address, pairing)).await {
            Ok(result) => result,
            Err(_) => Err(Failure::new(format!("the phone's developer services did not answer within {} s", timeout.as_secs())).fix(LOOPBACK_FIX).code("loopback")),
        }
    }

    async fn open_inner(address: IpAddr, pairing: &mut Pairing) -> Result<Self> {
        match pairing {
            Pairing::Remote { file, host_name } => {
                let (adapter, rsd, control) = remote::connect(address, file, host_name, |_| {}).await.map_err(remote_failure)?;
                Ok(Self { adapter, rsd, _control: Some(control) })
            }
            Pairing::Lockdown(file) => {
                let provider = TcpProvider { addr: address, scope_id: None, pairing_file: file.clone(), label: "Poki".into() };
                let proxy = CoreDeviceProxy::connect(&provider).await.map_err(|e| {
                    let text = e.to_string();
                    // A socket or TLS failure is the path to the phone, not the phone refusing the pairing.
                    let (fix, code) = if text.contains("onnect") || text.contains("refused") || text.contains("timed out") || text.contains("socket") || text.to_lowercase().contains("tls") { (LOOPBACK_FIX, "loopback") } else { (PAIRING_FIX, "pairing") };
                    Failure::new(format!("lockdown on {address}:62078 failed: {text}")).fix(fix).code(code)
                })?;
                let port = proxy.tunnel_info().server_rsd_port;
                let mut adapter = proxy.create_software_tunnel().map_err(|e| Failure::new(format!("the tunnel did not come up: {e}")))?.to_async_handle();
                let stream = adapter.connect(port).await.map_err(|e| Failure::new(format!("the RSD handshake failed: {e}")))?;
                let rsd = RsdHandshake::new(stream).await?;
                Ok(Self { adapter, rsd, _control: None })
            }
        }
    }

    pub async fn connect<S: RsdService>(&mut self) -> std::result::Result<S, idevice::IdeviceError> {
        S::connect_rsd(&mut self.adapter, &mut self.rsd).await
    }

    /// What the phone says about Developer Mode; None when it could not be read.
    pub async fn developer_mode(&mut self) -> Option<bool> {
        let mut lockdown: LockdownClient = self.connect().await.ok()?;
        lockdown.get_value(Some("DeveloperModeStatus"), Some("com.apple.security.mac.amfi")).await.ok()?.as_boolean()
    }

    pub async fn ios_version(&mut self) -> Result<String> {
        let mut lockdown: LockdownClient = self.connect().await?;
        let value = lockdown.get_value(Some("ProductVersion"), None).await?;
        Ok(value.as_string().unwrap_or("").to_string())
    }

    pub async fn installation_proxy(&mut self) -> Result<InstallationProxyClient> {
        Ok(self.connect().await?)
    }
}


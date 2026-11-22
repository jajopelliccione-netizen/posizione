//! Motore di Posizione: parla con l'iPhone stesso (tramite LocalDevVPN, 10.7.0.1)
//! e imposta la posizione simulata. Esposto al lato Swift con una piccola API C.

use std::ffi::{c_char, c_double, CStr, CString};
use std::net::IpAddr;
use std::sync::Mutex;

use idevice::{
    core_device_proxy::CoreDeviceProxy,
    remote_pairing::{connect_tls_psk_tunnel_native, RemotePairingClient, RpPairingFile, RpPairingSocket},
    tcp::adapter::Adapter,
    dvt::{location_simulation::LocationSimulationClient, remote_server::RemoteServerClient},
    pairing_file::PairingFile,
    provider::TcpProvider,
    rsd::RsdHandshake,
    IdeviceService, ReadWrite, RsdService,
};
use tokio::sync::mpsc;

enum Cmd {
    Set(f64, f64),
    Clear,
    Stop,
}

struct State {
    tx: mpsc::UnboundedSender<Cmd>,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);
static LAST_ERR: Mutex<String> = Mutex::new(String::new());

fn set_err(s: impl Into<String>) {
    *LAST_ERR.lock().unwrap() = s.into();
}

async fn session(
    pairing_path: String,
    mut rx: mpsc::UnboundedReceiver<Cmd>,
    ready: std::sync::mpsc::Sender<Result<(), String>>,
) {
    macro_rules! tryf {
        ($e:expr, $ctx:expr) => {
            match $e {
                Ok(v) => v,
                Err(e) => {
                    let _ = ready.send(Err(format!("{}: {:?}", $ctx, e)));
                    return;
                }
            }
        };
    }

    let pairing = tryf!(PairingFile::read_from_file(&pairing_path), "File di pairing");
    let provider = TcpProvider {
        addr: "10.7.0.1".parse::<IpAddr>().unwrap(),
        pairing_file: pairing,
        label: "Posizione".into(),
        scope_id: None,
    };
    let proxy = tryf!(
        CoreDeviceProxy::connect(&provider).await,
        "Connessione al telefono (LocalDevVPN attiva? Modalita sviluppatore?)"
    );
    let rsd_port = proxy.tunnel_info().server_rsd_port;
    let adapter = tryf!(proxy.create_software_tunnel(), "Tunnel");
    let mut handle = adapter.to_async_handle();
    let rsd_stream = tryf!(handle.connect(rsd_port).await, "RSD");
    let mut hs = tryf!(RsdHandshake::new(rsd_stream).await, "Handshake RSD");
    let mut rs: RemoteServerClient<Box<dyn ReadWrite>> = tryf!(
        RemoteServerClient::connect_rsd(&mut handle, &mut hs).await,
        "Servizio sviluppatore (immagine sviluppatore montata?)"
    );
    tryf!(rs.read_message(0).await, "Lettura iniziale");
    let mut loc = tryf!(LocationSimulationClient::new(&mut rs).await, "Canale posizione");
    let _ = ready.send(Ok(()));

    // La simulazione resta attiva finche questa connessione resta aperta.
    while let Some(cmd) = rx.recv().await {
        match cmd {
            Cmd::Set(la, lo) => {
                if let Err(e) = loc.set(la, lo).await {
                    set_err(format!("set: {:?}", e));
                }
            }
            Cmd::Clear => {
                if let Err(e) = loc.clear().await {
                    set_err(format!("clear: {:?}", e));
                }
            }
            Cmd::Stop => {
                let _ = loc.clear().await;
                break;
            }
        }
    }
}



async fn with_timeout<T, F>(secs: u64, f: F) -> Result<T, String>
where
    F: std::future::Future<Output = Result<T, idevice::IdeviceError>>,
{
    match tokio::time::timeout(std::time::Duration::from_secs(secs), f).await {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(e)) => Err(format!("{:?}", e)),
        Err(_) => Err("nessuna risposta".to_string()),
    }
}

async fn scan_ports(host: String, lo: u16, hi: u16) -> Vec<u16> {
    use tokio::task::JoinSet;
    let mut open: Vec<u16> = Vec::new();
    let mut port = lo as u32;
    while port <= hi as u32 {
        let end = (port + 128).min(hi as u32 + 1);
        let mut set = JoinSet::new();
        for p in port..end {
            let h = host.clone();
            set.spawn(async move {
                let r = tokio::time::timeout(
                    std::time::Duration::from_millis(250),
                    tokio::net::TcpStream::connect((h.as_str(), p as u16)),
                )
                .await;
                if let Ok(Ok(_s)) = r { Some(p as u16) } else { None }
            });
        }
        while let Some(res) = set.join_next().await {
            if let Ok(Some(p)) = res {
                open.push(p);
            }
        }
        port = end;
    }
    open.sort();
    open
}

/// Cerca le porte TCP aperte su `host` tra lo e hi. Ritorna "p1,p2,..." (da liberare con ll_free_string).
#[no_mangle]
pub extern "C" fn ll_scan_ports(host: *const c_char, lo: u16, hi: u16) -> *mut c_char {
    let host = unsafe { CStr::from_ptr(host) }.to_string_lossy().into_owned();
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime");
    let ports = rt.block_on(scan_ports(host, lo, hi));
    let text = ports.iter().map(|p| p.to_string()).collect::<Vec<_>>().join(",");
    CString::new(text).unwrap().into_raw()
}

async fn tcp_connect(host: &str, port: u16) -> Result<tokio::net::TcpStream, String> {
    let mut last = String::from("nessun indirizzo");
    let addrs = tokio::net::lookup_host((host, port)).await.map_err(|e| format!("{e}"))?;
    for a in addrs {
        match tokio::time::timeout(std::time::Duration::from_secs(8), tokio::net::TcpStream::connect(a)).await {
            Ok(Ok(s)) => return Ok(s),
            Ok(Err(e)) => last = format!("{a}: {e}"),
            Err(_) => last = format!("{a}: tempo scaduto"),
        }
    }
    Err(last)
}

async fn session_rp(
    pairing_path: String,
    host: String,
    port: u16,
    mut rx: mpsc::UnboundedReceiver<Cmd>,
    ready: std::sync::mpsc::Sender<Result<(), String>>,
) {
    macro_rules! tryf {
        ($e:expr, $ctx:expr) => {
            match $e {
                Ok(v) => v,
                Err(e) => {
                    let _ = ready.send(Err(format!("{}: {:?}", $ctx, e)));
                    return;
                }
            }
        };
    }
    let mut pf = tryf!(RpPairingFile::read_from_file(&pairing_path).await, "File rppairing");
    let sock = tryf!(tcp_connect(&host, port).await, format!("1 Connessione a {host}:{port}"));
    let mut client = RemotePairingClient::new(RpPairingSocket::new(sock), "posizione-host");
    tryf!(with_timeout(6, client.attempt_pair_verify()).await, "2 Handshake");
    tryf!(with_timeout(6, client.validate_pairing(&mut pf)).await, "3 Verifica abbinamento");
    let tport = tryf!(with_timeout(6, client.create_tcp_listener()).await, "4 Creazione tunnel");
    let stream = tryf!(tcp_connect(&host, tport).await, format!("5 Connessione al tunnel {host}:{tport}"));
    let tunnel = tryf!(
        connect_tls_psk_tunnel_native(stream, client.encryption_key()).await,
        "6 TLS del tunnel"
    );
    let info = tunnel.info.clone();
    let our_ip = tryf!(info.client_address.parse::<IpAddr>(), "IP client");
    let their_ip = tryf!(info.server_address.parse::<IpAddr>(), "IP server");
    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), our_ip, their_ip);
    adapter.set_mss((info.mtu as usize).saturating_sub(60));
    let mut handle = adapter.to_async_handle();
    let rsd_stream = tryf!(handle.connect(info.server_rsd_port).await, "7 RSD");
    let mut hs = tryf!(RsdHandshake::new(rsd_stream).await, "8 Handshake RSD");
    let mut rs: RemoteServerClient<Box<dyn ReadWrite>> = tryf!(
        RemoteServerClient::connect_rsd(&mut handle, &mut hs).await,
        "9 Servizio sviluppatore"
    );
    tryf!(rs.read_message(0).await, "10 Lettura iniziale");
    let mut loc = tryf!(LocationSimulationClient::new(&mut rs).await, "11 Canale posizione");
    let _ = ready.send(Ok(()));
    while let Some(cmd) = rx.recv().await {
        match cmd {
            Cmd::Set(la, lo) => {
                if let Err(e) = loc.set(la, lo).await {
                    set_err(format!("set: {:?}", e));
                }
            }
            Cmd::Clear => {
                if let Err(e) = loc.clear().await {
                    set_err(format!("clear: {:?}", e));
                }
            }
            Cmd::Stop => {
                let _ = loc.clear().await;
                break;
            }
        }
    }
}

/// Connessione iOS 27 (RPPairing). host = indirizzo, port = porta del servizio _remotepairing._tcp.
#[no_mangle]
pub extern "C" fn ll_connect_rp(pairing_path: *const c_char, host: *const c_char, port: u16) -> i32 {
    let path = unsafe { CStr::from_ptr(pairing_path) }.to_string_lossy().into_owned();
    let host = unsafe { CStr::from_ptr(host) }.to_string_lossy().into_owned();
    ll_disconnect();
    let (tx, rx) = mpsc::unbounded_channel();
    let (rtx, rrx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("runtime");
        rt.block_on(session_rp(path, host, port, rx, rtx));
    });
    match rrx.recv_timeout(std::time::Duration::from_secs(40)) {
        Ok(Ok(())) => {
            *STATE.lock().unwrap() = Some(State { tx });
            0
        }
        Ok(Err(e)) => {
            set_err(e);
            1
        }
        _ => {
            set_err("Tempo scaduto");
            1
        }
    }
}

/// Avvia la sessione (vecchio metodo, iOS <= 26). Ritorna 0 se ok, 1 se errore (vedi ll_last_error).
#[no_mangle]
pub extern "C" fn ll_connect(pairing_path: *const c_char) -> i32 {
    let path = unsafe { CStr::from_ptr(pairing_path) }.to_string_lossy().into_owned();
    ll_disconnect();
    let (tx, rx) = mpsc::unbounded_channel();
    let (rtx, rrx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        rt.block_on(session(path, rx, rtx));
    });
    match rrx.recv_timeout(std::time::Duration::from_secs(25)) {
        Ok(Ok(())) => {
            *STATE.lock().unwrap() = Some(State { tx });
            0
        }
        Ok(Err(e)) => {
            set_err(e);
            1
        }
        _ => {
            set_err("Tempo scaduto: controlla che LocalDevVPN sia connessa");
            1
        }
    }
}

#[no_mangle]
pub extern "C" fn ll_set_location(lat: c_double, lon: c_double) -> i32 {
    match STATE.lock().unwrap().as_ref() {
        Some(s) => s.tx.send(Cmd::Set(lat, lon)).map(|_| 0).unwrap_or(1),
        None => {
            set_err("Non connesso");
            1
        }
    }
}

#[no_mangle]
pub extern "C" fn ll_clear_location() -> i32 {
    match STATE.lock().unwrap().as_ref() {
        Some(s) => s.tx.send(Cmd::Clear).map(|_| 0).unwrap_or(1),
        None => 1,
    }
}

#[no_mangle]
pub extern "C" fn ll_disconnect() {
    if let Some(s) = STATE.lock().unwrap().take() {
        let _ = s.tx.send(Cmd::Stop);
    }
}

/// Stringa da liberare con ll_free_string.
#[no_mangle]
pub extern "C" fn ll_last_error() -> *mut c_char {
    CString::new(LAST_ERR.lock().unwrap().clone().replace('\0', " ")).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn ll_free_string(p: *mut c_char) {
    if !p.is_null() {
        unsafe { drop(CString::from_raw(p)) }
    }
}

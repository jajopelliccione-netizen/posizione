//! Motore di Posizione: parla con l'iPhone stesso (tramite LocalDevVPN, 10.7.0.1)
//! e imposta la posizione simulata. Esposto al lato Swift con una piccola API C.

use std::ffi::{c_char, c_double, CStr, CString};
use std::net::IpAddr;
use std::sync::Mutex;

use idevice::{
    core_device_proxy::CoreDeviceProxy,
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

/// Avvia la sessione. Ritorna 0 se ok, 1 se errore (vedi ll_last_error).
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

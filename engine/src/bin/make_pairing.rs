//! Crea sul Mac un file di pairing NUOVO per l'iPhone collegato.
//! Uso: cargo run --release --bin make_pairing [percorso_output]
//! Sul telefono potrebbe comparire "Autorizzare questo computer?": tocca Autorizza e inserisci il codice.
use idevice::{
    lockdown::LockdownClient,
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection},
    IdeviceService,
};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let out = std::env::args().nth(1).unwrap_or_else(|| {
        format!("{}/Desktop/pairing.plist", std::env::var("HOME").unwrap_or(".".into()))
    });
    let mut mux = UsbmuxdConnection::default().await.unwrap_or_else(|e| {
        eprintln!("Impossibile parlare con usbmuxd: {:?}", e);
        std::process::exit(1);
    });
    let devices = mux.get_devices().await.unwrap_or_default();
    let Some(dev) = devices.first() else {
        eprintln!("Nessun iPhone trovato. Collegalo col cavo, sbloccalo e tocca Autorizza.");
        std::process::exit(1);
    };
    println!("Trovato iPhone: {}", dev.udid);
    let buid = mux.get_buid().await.unwrap_or_else(|e| {
        eprintln!("BUID non leggibile: {:?}", e);
        std::process::exit(1);
    });
    let provider = dev.to_provider(UsbmuxdAddr::default(), "Posizione");
    let mut lockdown = LockdownClient::connect(&provider).await.unwrap_or_else(|e| {
        eprintln!("Connessione a lockdown fallita: {:?}", e);
        std::process::exit(1);
    });
    let host_id = uuid::Uuid::new_v4().to_string().to_uppercase();
    println!("Se compare sul telefono 'Autorizzare questo computer?', tocca Autorizza.");
    let pf = lockdown.pair(host_id, buid, Some("Posizione")).await.unwrap_or_else(|e| {
        eprintln!("Pairing fallito: {:?}", e);
        std::process::exit(1);
    });
    // verifica che la sessione funzioni col nuovo pairing
    if let Err(e) = lockdown.start_session(&pf).await {
        eprintln!("Attenzione: sessione di prova fallita: {:?}", e);
    }
    let bytes = pf.serialize().expect("serializzazione");
    std::fs::write(&out, bytes).expect("scrittura file");
    println!("Salvato in {}", out);
}

//! Legge dal Mac (tramite usbmuxd) il pairing dell'iPhone collegato e lo salva in un file.
//! Uso: cargo run --release --bin make_pairing [percorso_output]
use idevice::usbmuxd::UsbmuxdConnection;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let out = std::env::args().nth(1).unwrap_or_else(|| {
        format!("{}/Desktop/pairing.plist", std::env::var("HOME").unwrap_or(".".into()))
    });
    let mut mux = match UsbmuxdConnection::default().await {
        Ok(m) => m,
        Err(e) => {
            eprintln!("Impossibile parlare con usbmuxd: {:?}", e);
            std::process::exit(1);
        }
    };
    let devices = mux.get_devices().await.unwrap_or_default();
    let Some(dev) = devices.first() else {
        eprintln!("Nessun iPhone trovato. Collegalo col cavo, sbloccalo e tocca Autorizza.");
        std::process::exit(1);
    };
    println!("Trovato iPhone: {}", dev.udid);
    let pf = match mux.get_pair_record(&dev.udid).await {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Pairing non leggibile: {:?}", e);
            std::process::exit(1);
        }
    };
    let bytes = pf.serialize().expect("serializzazione");
    std::fs::write(&out, bytes).expect("scrittura file");
    println!("Salvato in {}", out);
}

//! Tappa 1 per iOS 27: il Mac si presenta come "host abbinabile" e l'iPhone avvia il pairing.
//! Uso: cargo run --release --bin rp_pair [percorso_output]
use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket,
};
use std::process::Stdio;
use tokio::net::TcpListener;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let out = std::env::args().nth(1).unwrap_or_else(|| {
        format!("{}/Desktop/rppairing.plist", std::env::var("HOME").unwrap_or(".".into()))
    });

    let info = PairableHostInfo::generate("Mac di Jacopo", "Mac15,3");
    let mut pf = RpPairingFile::generate("posizione-host");
    let ident = pf.identifier().to_string();

    let listener = TcpListener::bind("0.0.0.0:0").await.expect("porta");
    let port = listener.local_addr().unwrap().port();
    println!("In ascolto sulla porta {port}");

    // Annuncio mDNS con dns-sd (incluso in macOS)
    let mut cmd = tokio::process::Command::new("dns-sd");
    cmd.arg("-R").arg(&ident).arg("_remotepairing-pairable-host._tcp").arg("local").arg(port.to_string());
    for (k, v) in info.mdns_txt_records(&ident) {
        cmd.arg(format!("{k}={v}"));
    }
    cmd.stdout(Stdio::null()).stderr(Stdio::inherit()).kill_on_drop(true);
    let _adv = cmd.spawn().expect("dns-sd non avviabile");

    println!();
    println!("Ora sull'iPhone cerca il Mac tra i dispositivi da abbinare (vedi istruzioni) e avvia l'abbinamento.");
    println!("In attesa dell'iPhone... (Ctrl+C per uscire)");

    loop {
        let (sock, addr) = listener.accept().await.expect("accept");
        println!("Connessione da {addr}");
        let sock = RpPairingSocket::new_device(sock);
        let mut host = PairableHost::new(sock, info.clone());
        let res = host
            .accept(&mut pf, |pin| async move {
                println!();
                println!("==========================");
                println!("  CODICE PIN: {pin}");
                println!("==========================");
                println!("Scrivilo sull'iPhone.");
            })
            .await;
        match res {
            Ok(_) => {
                pf.write_to_file(&out).await.expect("scrittura file");
                println!("Abbinamento riuscito. Salvato in {out}");
                return;
            }
            Err(e) => {
                eprintln!("Abbinamento fallito: {e:?}. Riprovo, in attesa...");
            }
        }
    }
}

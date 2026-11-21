# Posizione

App iPhone (iOS 17+) per cambiare la posizione dal telefono, senza computer dopo l'installazione.
Stesso metodo di LiveLoc: una VPN locale (LocalDevVPN) permette all'app di parlare con i servizi
sviluppatore del telefono stesso e impostare la posizione simulata.

NOTA: scritta e compilata (solo la parte Rust) senza poterla provare su un iPhone vero.
Il primo avvio potrebbe richiedere piccoli aggiustamenti.

## Installazione (una volta, sul Mac)
1. Installa: Xcode, Rust (rustup.rs), XcodeGen (`brew install xcodegen`).
2. `./build_engine.sh`
3. `cd App && xcodegen && open Posizione.xcodeproj`
4. In Xcode: target Posizione > Signing > scegli il tuo Apple ID, cambia il Bundle Identifier
   (es. com.tuonome.posizione). Collega l'iPhone, premi Run.
   Con Apple ID gratuito l'app dura 7 giorni, poi va reinstallata da Xcode.
5. Sull'iPhone: Impostazioni > Privacy e sicurezza > Modalità sviluppatore: attiva e riavvia.
   (Collegato a Xcode, l'immagine sviluppatore viene montata da sola.)
6. Genera il file di pairing del telefono (`pairing.plist`) con uno strumento tipo idevice_pair
   (jkcoxson) e mandalo al telefono (AirDrop / File).
7. Installa LocalDevVPN dall'App Store.

## Uso (solo telefono)
1. Apri LocalDevVPN e attivala.
2. Apri Posizione, la prima volta "Importa file di pairing".
3. Premi Connetti, cerca un luogo o tocca la mappa, premi Imposta posizione.
4. "Posizione reale" per tornare alla tua posizione.
La simulazione resta finché la connessione dell'app è aperta: tieni l'app e la VPN attive.

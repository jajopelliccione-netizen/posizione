//! Prova su PC della diagnostica: probe_cli <host> <porta_da> <porta_a>
#[tokio::main(flavor = "current_thread")]
async fn main() {
    let a: Vec<String> = std::env::args().collect();
    let host = a.get(1).cloned().unwrap_or("127.0.0.1".into());
    let lo: u16 = a.get(2).and_then(|x| x.parse().ok()).unwrap_or(40000);
    let hi: u16 = a.get(3).and_then(|x| x.parse().ok()).unwrap_or(40100);
    println!("{}", posizione_engine::probe_report(vec![host], vec![(lo, hi)]).await);
}

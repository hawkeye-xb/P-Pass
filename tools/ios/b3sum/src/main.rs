use std::io::Read;

fn main() {
    for path in std::env::args().skip(1) {
        let mut f = std::fs::File::open(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
        let mut h = blake3::Hasher::new();
        let mut buf = vec![0u8; 1 << 20];
        loop {
            let n = f.read(&mut buf).unwrap();
            if n == 0 {
                break;
            }
            h.update(&buf[..n]);
        }
        println!("{}  {}", h.finalize().to_hex(), path);
    }
}

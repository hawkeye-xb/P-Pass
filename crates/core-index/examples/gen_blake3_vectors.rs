fn main() {
    // Deterministic 1 MiB, same xorshift as the resume test.
    let mut v = Vec::with_capacity(1 << 20);
    let mut s: u64 = 0x5EED_2026_0731_0053;
    while v.len() < (1 << 20) {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        v.extend_from_slice(&s.to_le_bytes());
    }
    v.truncate(1 << 20);
    let cases: Vec<(&str, Vec<u8>)> = vec![
        ("empty", vec![]),
        ("hello", b"hello".to_vec()),
        ("photo_bytes_1MiB_xorshift_5EED202607310053", v),
    ];
    println!("[");
    for (i, (name, data)) in cases.iter().enumerate() {
        let h = blake3::hash(data);
        let comma = if i + 1 == cases.len() { "" } else { "," };
        println!(
            "  {{\"name\": \"{}\", \"len\": {}, \"blake3_hex\": \"{}\"}}{}",
            name,
            data.len(),
            h.to_hex(),
            comma
        );
    }
    println!("]");
}

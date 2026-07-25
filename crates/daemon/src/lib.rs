//! Daemon — service lifecycle, ALPN routing, IPC, telemetry client.
//!
//! No `unwrap`/`expect` allowed in production code (CI-enforced).

pub fn add(left: u64, right: u64) -> u64 {
    left + right
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholder() {
        assert_eq!(add(2, 2), 4);
    }
}

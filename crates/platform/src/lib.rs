//! Platform — PlatformAdapter trait + Windows/macOS implementations.
//!
//! Architecture enforcement: this is the ONLY crate allowed to use
//! `#[cfg(windows)]` / `#[cfg(target_os = "macos")]`.

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

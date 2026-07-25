//! P-Pass protocol — message schemas, version negotiation, error codes.
//!
//! This crate is the single source of truth for all wire types.
//! Kotlin types are generated from the JSON Schema exported here.

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

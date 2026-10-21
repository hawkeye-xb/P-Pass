//! P-Pass protocol — version constants and the compatibility rule (#1070).
//!
//! Every `Req` / `Resp` carries the sender's `ver` (its [`PROTO_VER`]) and
//! `min_ver` (its [`MIN_SUPPORTED_VER`]). Only an incompatible change
//! (removing a field, changing a meaning, making a field required) bumps
//! `PROTO_VER`; adding an optional field or a `Reason` does not. The ALPN
//! never follows this number — it stays `ppf/ctrl/1`, so an outdated peer
//! still connects and gets a readable "please update" answer.

use crate::error::Reason;

/// Current wire protocol version.
pub const PROTO_VER: u16 = 2;

/// Oldest peer version this build still serves. Always equal to
/// [`PROTO_VER`]: no dual-version window is kept.
pub const MIN_SUPPORTED_VER: u16 = 2;

// No dual-version window: checked at compile time.
const _: () = assert!(PROTO_VER == MIN_SUPPORTED_VER);

/// A peer that sends no `ver` / `min_ver` predates protocol v2.
pub const V1: u16 = 1;

/// One side's declared versions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Versions {
    pub ver: u16,
    pub min_ver: u16,
}

impl Versions {
    /// This build.
    pub const LOCAL: Versions = Versions {
        ver: PROTO_VER,
        min_ver: MIN_SUPPORTED_VER,
    };
}

/// Which end of the link the caller is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Desktop,
    Phone,
}

/// The compatibility rule, shared by the daemon and both phones' tests.
/// `Err` names the device that must update: the peer when it is older than
/// we accept, else ourselves when we are older than the peer accepts.
pub fn compatibility(local: Versions, peer: Versions, local_role: Role) -> Result<(), Reason> {
    let outdated = |peer_is_outdated: bool| match (local_role, peer_is_outdated) {
        (Role::Desktop, true) | (Role::Phone, false) => Reason::PhoneOutdated,
        (Role::Desktop, false) | (Role::Phone, true) => Reason::DesktopOutdated,
    };
    if peer.ver < local.min_ver {
        return Err(outdated(true));
    }
    if local.ver < peer.min_ver {
        return Err(outdated(false));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const fn v(ver: u16, min_ver: u16) -> Versions {
        Versions { ver, min_ver }
    }

    #[test]
    fn peer_without_ver_is_v1_and_too_old() {
        // A v1 envelope decodes to ver = min_ver = 1 (see `Req`).
        assert_eq!(
            compatibility(Versions::LOCAL, v(V1, V1), Role::Desktop),
            Err(Reason::PhoneOutdated)
        );
        assert_eq!(
            compatibility(Versions::LOCAL, v(V1, V1), Role::Phone),
            Err(Reason::DesktopOutdated)
        );
    }

    #[test]
    fn peer_below_our_min_is_outdated() {
        assert_eq!(
            compatibility(v(3, 3), v(2, 2), Role::Desktop),
            Err(Reason::PhoneOutdated)
        );
    }

    #[test]
    fn equal_versions_are_compatible() {
        assert_eq!(
            compatibility(Versions::LOCAL, Versions::LOCAL, Role::Desktop),
            Ok(())
        );
        assert_eq!(compatibility(v(2, 2), v(2, 2), Role::Phone), Ok(()));
    }

    #[test]
    fn peer_above_us_is_fine_unless_it_drops_our_version() {
        // A newer peer that still accepts us: compatible.
        assert_eq!(compatibility(v(2, 2), v(3, 2), Role::Desktop), Ok(()));
        // A newer peer whose min is above us: WE are outdated.
        assert_eq!(
            compatibility(v(2, 2), v(3, 3), Role::Desktop),
            Err(Reason::DesktopOutdated)
        );
        assert_eq!(
            compatibility(v(2, 2), v(3, 3), Role::Phone),
            Err(Reason::PhoneOutdated)
        );
    }
}

//! NET-26 (#419): keep the machine awake while any transfer is running.
//!
//! `platform::PlatformAdapter::assert_awake` has existed since T-040 but no
//! production path ever called it, so a phone push could be cut off by idle
//! sleep mid-transfer. [`AwakeHold`] is a reference count over that guard:
//! the first [`AwakeLease`] acquires the platform assertion, the last one to
//! drop releases it. Leases are RAII, so success, failure, cancellation and
//! panics all release through the same `Drop`.
//!
//! The acquirer is injectable so tests can observe acquire/release without
//! touching the real power state; the daemon itself uses
//! [`AwakeHold::platform`]. No platform `cfg` here — the per-OS mechanics
//! live behind the platform crate (arch-check B.2).

use std::sync::{Arc, Mutex};

/// Opaque token whose `Drop` releases one platform assertion.
pub type AwakeToken = Box<dyn Send>;

type Acquire = dyn Fn() -> Option<AwakeToken> + Send + Sync;

/// Reference-counted "stay awake" holder. Cheap to clone; clones share the
/// same count.
#[derive(Clone)]
pub struct AwakeHold {
    acquire: Arc<Acquire>,
    state: Arc<Mutex<HoldState>>,
}

#[derive(Default)]
struct HoldState {
    leases: usize,
    token: Option<AwakeToken>,
}

impl AwakeHold {
    /// Holder backed by an arbitrary acquirer. `None` from the acquirer
    /// means "could not assert" — the lease still counts, the transfer
    /// proceeds, nothing is held.
    pub fn new(acquire: impl Fn() -> Option<AwakeToken> + Send + Sync + 'static) -> Self {
        Self {
            acquire: Arc::new(acquire),
            state: Arc::default(),
        }
    }

    /// Never asserts anything — the default for component construction and
    /// tests that don't care about power state.
    pub fn noop() -> Self {
        Self::new(|| None)
    }

    /// Production holder: the platform's `assert_awake`. A failure to
    /// assert is logged and never fails the transfer (best effort, §4).
    pub fn platform() -> Self {
        Self::new(|| {
            use platform::PlatformAdapter as _;
            match platform::adapter().assert_awake() {
                Ok(guard) => {
                    tracing::debug!("awake assertion acquired for active transfers");
                    Some(Box::new(guard) as AwakeToken)
                }
                Err(e) => {
                    tracing::warn!("assert_awake failed; transfer may be cut by idle sleep: {e}");
                    None
                }
            }
        })
    }

    /// Take one lease. The 0→1 transition acquires the platform assertion.
    pub fn lease(&self) -> AwakeLease {
        let mut state = self.state.lock().expect("awake hold lock");
        if state.leases == 0 {
            state.token = (self.acquire)();
        }
        state.leases += 1;
        AwakeLease {
            state: Arc::clone(&self.state),
        }
    }

    /// Number of live leases (diagnostics/tests).
    pub fn active_leases(&self) -> usize {
        self.state.lock().expect("awake hold lock").leases
    }
}

/// One running transfer's claim on the awake assertion. Dropping the last
/// lease releases the platform assertion.
pub struct AwakeLease {
    state: Arc<Mutex<HoldState>>,
}

impl Drop for AwakeLease {
    fn drop(&mut self) {
        let released = {
            let mut state = self.state.lock().expect("awake hold lock");
            state.leases -= 1;
            if state.leases == 0 {
                state.token.take()
            } else {
                None
            }
        };
        // Release outside the lock: a platform guard's Drop may block
        // briefly (killing caffeinate / joining the Windows awake thread).
        drop(released);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Counted(Arc<AtomicUsize>);
    impl Drop for Counted {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn counting() -> (AwakeHold, Arc<AtomicUsize>, Arc<AtomicUsize>) {
        let acquired = Arc::new(AtomicUsize::new(0));
        let released = Arc::new(AtomicUsize::new(0));
        let (a, r) = (Arc::clone(&acquired), Arc::clone(&released));
        let hold = AwakeHold::new(move || {
            a.fetch_add(1, Ordering::SeqCst);
            Some(Box::new(Counted(Arc::clone(&r))) as AwakeToken)
        });
        (hold, acquired, released)
    }

    #[test]
    fn first_lease_acquires_and_last_lease_releases() {
        let (hold, acquired, released) = counting();
        let first = hold.lease();
        let second = hold.clone().lease();
        assert_eq!(
            acquired.load(Ordering::SeqCst),
            1,
            "overlap shares one assertion"
        );
        drop(first);
        assert_eq!(
            released.load(Ordering::SeqCst),
            0,
            "still one transfer running"
        );
        drop(second);
        assert_eq!(released.load(Ordering::SeqCst), 1, "last lease releases");
        assert_eq!(hold.active_leases(), 0);

        let _again = hold.lease();
        assert_eq!(acquired.load(Ordering::SeqCst), 2, "idle→busy re-acquires");
    }

    #[test]
    fn failed_acquire_still_counts_and_retries_next_cycle() {
        let calls = Arc::new(AtomicUsize::new(0));
        let c = Arc::clone(&calls);
        let hold = AwakeHold::new(move || {
            c.fetch_add(1, Ordering::SeqCst);
            None
        });
        let lease = hold.lease();
        assert_eq!(hold.active_leases(), 1);
        drop(lease);
        let _lease = hold.lease();
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }
}

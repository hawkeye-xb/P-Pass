//! Low-priority thumbnail worker pool (契约: 全管线低优先级线程池，索引
//! 期间不抢用户机器；并发度可配).
//!
//! IDX-06 (#442): the daemon's pre-generation path runs on this pool. Two
//! additions for it: the generator is injectable (the daemon hands in the
//! same function `thumb.get` uses, so both paths count as one generator
//! in contract tests), and `submit_with` takes a completion callback, so an
//! async caller can bridge the result into a tokio channel without parking
//! a blocking thread on `mpsc::Receiver::recv`.

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;

use crate::thumb::{make_thumbs, ThumbResult};

/// A thumbnail generator: `(hash, src, thumbs_root) -> ThumbResult`.
/// Production is always [`make_thumbs`]; the indirection exists so callers
/// can count invocations in tests.
pub type ThumbGenerator =
    Arc<dyn Fn(&[u8; 32], &Path, &Path) -> ThumbResult + Send + Sync + 'static>;

type Reply = Box<dyn FnOnce(ThumbResult) + Send + 'static>;

struct Job {
    hash: [u8; 32],
    src: PathBuf,
    reply: Reply,
}

/// A fixed pool of worker threads generating thumbnails at the lowest
/// scheduling priority the OS grants us (best effort — a refusal is not
/// an error, just a normal-priority worker).
///
/// Note the scope of "low priority": it applies to the worker thread
/// itself. A video first frame is extracted by a child process (ffmpeg /
/// qlmanage), which does not inherit a thread's scheduling priority.
pub struct ThumbPool {
    tx: Option<mpsc::Sender<Job>>,
    workers: Vec<thread::JoinHandle<()>>,
}

impl ThumbPool {
    /// `workers` is clamped to at least 1. `thumbs_root` is where all
    /// thumbs land (§4.2 `.ppf/thumbs/`).
    pub fn new(workers: usize, thumbs_root: PathBuf) -> Self {
        Self::with_generator(
            workers,
            thumbs_root,
            Arc::new(|hash: &[u8; 32], src: &Path, root: &Path| make_thumbs(hash, src, root)),
        )
    }

    /// Same pool, custom generator. Worker threads are named `thumb-<i>`.
    pub fn with_generator(workers: usize, thumbs_root: PathBuf, generator: ThumbGenerator) -> Self {
        let (tx, rx) = mpsc::channel::<Job>();
        let rx = Arc::new(Mutex::new(rx));
        let handles = (0..workers.max(1))
            .map(|i| {
                let rx = Arc::clone(&rx);
                let root = thumbs_root.clone();
                let generator = Arc::clone(&generator);
                thread::Builder::new()
                    .name(format!("thumb-{i}"))
                    .spawn(move || {
                        let _ = thread_priority::set_current_thread_priority(
                            thread_priority::ThreadPriority::Min,
                        );
                        loop {
                            // Holding the lock only for recv keeps workers
                            // pulling jobs one at a time.
                            let job = match rx.lock() {
                                Ok(guard) => guard.recv(),
                                Err(_) => break,
                            };
                            let Ok(job) = job else { break };
                            // A panicking generator must not take the worker
                            // down with it: a pool that silently loses
                            // threads eventually stops answering at all. The
                            // reply is dropped unanswered instead, which the
                            // caller observes as a closed channel.
                            let result =
                                std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                                    generator(&job.hash, &job.src, &root)
                                }));
                            if let Ok(result) = result {
                                // Receiver may be gone (caller lost interest)
                                // — the thumb files are still on disk, fine.
                                (job.reply)(result);
                            }
                        }
                    })
                    .expect("spawning a named thread cannot fail on supported platforms")
            })
            .collect();
        Self {
            tx: Some(tx),
            workers: handles,
        }
    }

    /// Queue one thumbnail job; the returned channel yields its result.
    pub fn submit(&self, hash: [u8; 32], src: PathBuf) -> mpsc::Receiver<ThumbResult> {
        let (reply, result) = mpsc::channel();
        self.submit_with(hash, src, move |r| {
            let _ = reply.send(r);
        });
        result
    }

    /// Queue one job; `done` runs on the worker thread with its result.
    /// If the pool can no longer accept work, or the generator panics,
    /// `done` is dropped without being called — callers that bridge it into
    /// a channel see the channel close and must treat that as a failure.
    pub fn submit_with(
        &self,
        hash: [u8; 32],
        src: PathBuf,
        done: impl FnOnce(ThumbResult) + Send + 'static,
    ) {
        if let Some(tx) = &self.tx {
            let _ = tx.send(Job {
                hash,
                src,
                reply: Box::new(done),
            });
        }
    }
}

impl Drop for ThumbPool {
    fn drop(&mut self) {
        // Close the queue, then let in-flight jobs finish.
        self.tx.take();
        for h in self.workers.drain(..) {
            let _ = h.join();
        }
    }
}

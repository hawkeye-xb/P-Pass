//! Low-priority thumbnail worker pool (契约: 全管线低优先级线程池，索引
//! 期间不抢用户机器；并发度可配).

use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;

use crate::thumb::{make_thumbs, ThumbResult};

struct Job {
    hash: [u8; 32],
    src: PathBuf,
    reply: mpsc::Sender<ThumbResult>,
}

/// A fixed pool of worker threads generating thumbnails at the lowest
/// scheduling priority the OS grants us (best effort — a refusal is not
/// an error, just a normal-priority worker).
pub struct ThumbPool {
    tx: Option<mpsc::Sender<Job>>,
    workers: Vec<thread::JoinHandle<()>>,
}

impl ThumbPool {
    /// `workers` is clamped to at least 1. `thumbs_root` is where all
    /// thumbs land (§4.2 `.ppf/thumbs/`).
    pub fn new(workers: usize, thumbs_root: PathBuf) -> Self {
        let (tx, rx) = mpsc::channel::<Job>();
        let rx = Arc::new(Mutex::new(rx));
        let handles = (0..workers.max(1))
            .map(|i| {
                let rx = Arc::clone(&rx);
                let root = thumbs_root.clone();
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
                            let result = make_thumbs(&job.hash, &job.src, &root);
                            // Receiver may be gone (caller lost interest) —
                            // the thumb files are still on disk, fine.
                            let _ = job.reply.send(result);
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
        if let Some(tx) = &self.tx {
            let _ = tx.send(Job { hash, src, reply });
        }
        result
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

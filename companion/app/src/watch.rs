use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::{
    ffi::OsStr,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, RecvTimeoutError},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use crate::saved_variables::FILE_NAME;

const POLL: Duration = Duration::from_millis(50);

/// Quiet deadline for coalescing filesystem bursts into one settle.
#[derive(Debug, Default)]
pub struct SettleGate {
    deadline: Option<Instant>,
}

impl SettleGate {
    pub const QUIET: Duration = Duration::from_secs(1);

    /// Push the quiet deadline to `now + QUIET`.
    pub fn note(&mut self, now: Instant) {
        self.deadline = Some(now + Self::QUIET);
    }

    /// Return true once when the deadline has passed, then clear it.
    pub fn take_ready(&mut self, now: Instant) -> bool {
        match self.deadline {
            Some(deadline) if now >= deadline => {
                self.deadline = None;
                true
            }
            _ => false,
        }
    }
}

/// Owns the watch thread. Dropping this stops the watcher and joins the thread.
pub struct Watch {
    stop: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
}

impl Drop for Watch {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

impl Watch {
    /// Watch the parent of `path` and call `on_settled` after `Arbitrage.lua` is quiet.
    ///
    /// Returns `None` when `path` has no parent or the watcher cannot be started.
    pub fn start(path: &Path, on_settled: impl Fn() + Send + 'static) -> Option<Self> {
        let parent = path.parent()?.to_path_buf();
        Self::start_in([parent], RecursiveMode::NonRecursive, on_settled)
    }

    /// Watch the deepest existing data directory under each product root.
    ///
    /// This catches the first creation of `Arbitrage.lua`, including creation of its account and
    /// `SavedVariables` directories, without polling.
    pub fn discover(roots: &[PathBuf], on_settled: impl Fn() + Send + 'static) -> Option<Self> {
        let directories = roots.iter().filter_map(|root| discovery_directory(root));
        Self::start_in(directories, RecursiveMode::Recursive, on_settled)
    }

    fn start_in(
        directories: impl IntoIterator<Item = PathBuf>,
        recursive_mode: RecursiveMode,
        on_settled: impl Fn() + Send + 'static,
    ) -> Option<Self> {
        let (tx, rx) = mpsc::channel::<notify::Result<Event>>();
        let mut watcher = RecommendedWatcher::new(tx, notify::Config::default()).ok()?;
        let mut watching = false;
        for directory in directories {
            if watcher.watch(&directory, recursive_mode).is_ok() {
                watching = true;
            }
        }
        if !watching {
            return None;
        }

        let stop = Arc::new(AtomicBool::new(false));
        let stop_flag = Arc::clone(&stop);
        let join = thread::spawn(move || {
            let _watcher = watcher;
            let mut gate = SettleGate::default();

            while !stop_flag.load(Ordering::SeqCst) {
                match rx.recv_timeout(POLL) {
                    Ok(Ok(event)) => {
                        if event_targets_arbitrage(&event) {
                            gate.note(Instant::now());
                        }
                    }
                    Ok(Err(_)) | Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => break,
                }

                if gate.take_ready(Instant::now()) {
                    on_settled();
                }
            }
        });

        Some(Self {
            stop,
            join: Some(join),
        })
    }
}

fn discovery_directory(root: &Path) -> Option<PathBuf> {
    let account = root.join("WTF").join("Account");
    if account.is_dir() {
        return Some(account);
    }
    let wtf = root.join("WTF");
    if wtf.is_dir() {
        return Some(wtf);
    }
    root.is_dir().then(|| root.to_path_buf())
}

fn event_targets_arbitrage(event: &Event) -> bool {
    event.paths.iter().any(|path| is_arbitrage_lua(path))
}

fn is_arbitrage_lua(path: &Path) -> bool {
    path.file_name() == Some(OsStr::new(FILE_NAME))
}

#[cfg(test)]
mod tests {
    use super::{FILE_NAME, SettleGate, Watch, discovery_directory};
    use crate::saved_variables::temp;
    use std::{
        fs,
        io::Write,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
            mpsc,
        },
        time::{Duration, Instant},
    };

    #[test]
    fn settle_gate_waits_one_second_after_the_last_note() {
        let mut gate = SettleGate::default();
        let t0 = Instant::now();

        gate.note(t0);
        gate.note(t0 + Duration::from_millis(100));

        assert!(!gate.take_ready(t0 + Duration::from_millis(100) + Duration::from_millis(999)));
        assert!(gate.take_ready(t0 + Duration::from_millis(100) + Duration::from_secs(1)));
        assert!(!gate.take_ready(t0 + Duration::from_millis(100) + Duration::from_secs(2)));
    }

    #[test]
    fn discovery_uses_the_deepest_existing_data_directory() {
        let root = temp::Dir::new("watch-discovery");
        assert_eq!(
            discovery_directory(root.path()).as_deref(),
            Some(root.path())
        );

        let wtf = root.path().join("WTF");
        fs::create_dir(&wtf).expect("create WTF");
        assert_eq!(discovery_directory(root.path()), Some(wtf.clone()));

        let account = wtf.join("Account");
        fs::create_dir(&account).expect("create Account");
        assert_eq!(discovery_directory(root.path()), Some(account));
    }

    #[test]
    fn settled_write_invokes_the_callback_once() {
        let directory = temp::Dir::new("watch-settle");
        let file = directory.path().join(FILE_NAME);
        fs::write(&file, b"start\n").expect("seed file");

        let hits = Arc::new(AtomicUsize::new(0));
        let hits_for_callback = Arc::clone(&hits);
        let (ready_tx, ready_rx) = mpsc::channel();
        let watch = Watch::start(&file, move || {
            hits_for_callback.fetch_add(1, Ordering::SeqCst);
            let _ = ready_tx.send(());
        })
        .expect("watcher should start");

        // Give FSEvents a moment to attach before the write.
        std::thread::sleep(Duration::from_millis(200));

        let mut handle = fs::OpenOptions::new()
            .append(true)
            .open(&file)
            .expect("append open");
        handle.write_all(b"more\n").expect("append bytes");
        handle.flush().expect("flush");
        drop(handle);

        ready_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("settled callback should fire within a few seconds");
        assert_eq!(hits.load(Ordering::SeqCst), 1);

        assert!(
            ready_rx.recv_timeout(Duration::from_millis(1500)).is_err(),
            "a single append must not fire a second settle"
        );

        drop(watch);
    }
}

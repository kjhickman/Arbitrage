use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::{
    ffi::OsStr,
    fmt,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, RecvTimeoutError},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const FILE_NAME: &str = "Arbitrage.lua";
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

/// Failure starting a `SavedVariables` directory watch.
#[derive(Debug)]
pub enum Error {
    /// The watched file has no parent directory.
    MissingParent,
    /// The underlying notify watcher failed.
    Notify(notify::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingParent => {
                write!(formatter, "SavedVariables path has no parent directory")
            }
            Self::Notify(error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for Error {}

impl Watch {
    /// Watch the parent of `path` and call `on_settled` after `Arbitrage.lua` is quiet.
    ///
    /// # Errors
    ///
    /// Returns [`Error::MissingParent`] when `path` has no parent, or
    /// [`Error::Notify`] when the watcher cannot be created or started.
    pub fn start(path: &Path, on_settled: impl Fn() + Send + 'static) -> Result<Self, Error> {
        let parent = path.parent().ok_or(Error::MissingParent)?.to_path_buf();

        let (tx, rx) = mpsc::channel::<notify::Result<Event>>();
        let mut watcher =
            RecommendedWatcher::new(tx, notify::Config::default()).map_err(Error::Notify)?;
        watcher
            .watch(&parent, RecursiveMode::NonRecursive)
            .map_err(Error::Notify)?;

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

        Ok(Self {
            stop,
            join: Some(join),
        })
    }
}

fn event_targets_arbitrage(event: &Event) -> bool {
    event.paths.iter().any(|path| is_arbitrage_lua(path))
}

fn is_arbitrage_lua(path: &Path) -> bool {
    path.file_name() == Some(OsStr::new(FILE_NAME))
}

#[cfg(test)]
mod tests {
    use super::{FILE_NAME, SettleGate, Watch};
    use std::{
        env, fs,
        io::Write,
        path::PathBuf,
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
    fn settled_write_invokes_the_callback_once() {
        let directory = temp_dir("watch-settle");
        let file = directory.join(FILE_NAME);
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
        let _ = fs::remove_dir_all(&directory);
    }

    fn temp_dir(label: &str) -> PathBuf {
        let path = env::temp_dir().join(format!(
            "arbitrage-watch-{label}-{}-{}",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        ));
        fs::create_dir_all(&path).expect("temp directory");
        path
    }
}

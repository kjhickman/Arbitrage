mod codec;
mod locate;
mod lua;

pub use locate::locate;

use arbitrage_shared::Database;
use codec::{DecodeError, Newline};
use std::{
    fmt,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    ops::Range,
    path::{Path, PathBuf},
};

const DATABASE_NAME: &[u8] = b"ARBITRAGE_DATABASE";
const BACKUP_SUFFIX: &str = ".companion.bak";
const TEMP_PREFIX: &str = ".companion-";
const TEMP_ATTEMPTS: usize = 16;

#[derive(Debug)]
pub enum LoadError {
    Read(io::Error),
    Syntax(lua::Error),
    MissingDatabase,
    DuplicateDatabase,
    Decode(DecodeError),
}

impl fmt::Display for LoadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Read(error) => {
                write!(formatter, "the saved variables file is unreadable: {error}")
            }
            Self::Syntax(error) => {
                write!(formatter, "the saved variables file is malformed: {error}")
            }
            Self::MissingDatabase => write!(
                formatter,
                "the saved variables file has no Arbitrage database"
            ),
            Self::DuplicateDatabase => {
                write!(
                    formatter,
                    "the saved variables file has more than one Arbitrage database"
                )
            }
            Self::Decode(error) => error.fmt(formatter),
        }
    }
}

#[derive(Debug)]
pub enum StoreError {
    Write(io::Error),
    EncodeMismatch,
    ChangedOnDisk,
}

impl fmt::Display for StoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Write(error) => {
                write!(formatter, "the saved variables file is unwritable: {error}")
            }
            Self::EncodeMismatch => {
                write!(
                    formatter,
                    "the rewritten saved variables file did not match the database"
                )
            }
            Self::ChangedOnDisk => {
                write!(
                    formatter,
                    "the saved variables file changed since it was read"
                )
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreOutcome {
    Unchanged,
    Written,
}

/// One account's `Arbitrage.lua`, held as the bytes that were read plus the database span.
///
/// Every byte outside the span is opaque and is written back unchanged.
pub struct SavedVariables {
    path: PathBuf,
    snapshot: Vec<u8>,
    span: Range<usize>,
    database: Database,
}

impl SavedVariables {
    pub fn load(path: &Path) -> Result<Self, LoadError> {
        let snapshot = fs::read(path).map_err(LoadError::Read)?;
        let span = database_span(&snapshot)?;
        let value = lua::parse_value(&snapshot[span.clone()]).map_err(LoadError::Syntax)?;
        let database = codec::decode(&value).map_err(LoadError::Decode)?;

        Ok(Self {
            path: path.to_path_buf(),
            snapshot,
            span,
            database,
        })
    }

    pub const fn database(&self) -> &Database {
        &self.database
    }

    pub fn store(&mut self, database: &Database) -> Result<StoreOutcome, StoreError> {
        let encoded = codec::encode(database, self.newline());

        let mut updated = Vec::with_capacity(self.snapshot.len() + encoded.len());
        updated.extend_from_slice(&self.snapshot[..self.span.start]);
        updated.extend_from_slice(&encoded);
        updated.extend_from_slice(&self.snapshot[self.span.end..]);

        if updated == self.snapshot {
            return Ok(StoreOutcome::Unchanged);
        }

        let span = self.verify(&updated, database)?;

        let current = fs::read(&self.path).map_err(StoreError::Write)?;
        if current != self.snapshot {
            return Err(StoreError::ChangedOnDisk);
        }

        replace(&self.backup_path(), &self.snapshot).map_err(StoreError::Write)?;
        replace(&self.path, &updated).map_err(StoreError::Write)?;

        self.snapshot = updated;
        self.span = span;
        self.database = database.clone();
        Ok(StoreOutcome::Written)
    }

    /// Reads back what was just built, so a splice that lost bytes never reaches the disk.
    fn verify(&self, updated: &[u8], database: &Database) -> Result<Range<usize>, StoreError> {
        let span = database_span(updated).map_err(|_| StoreError::EncodeMismatch)?;
        let value =
            lua::parse_value(&updated[span.clone()]).map_err(|_| StoreError::EncodeMismatch)?;
        let decoded = codec::decode(&value).map_err(|_| StoreError::EncodeMismatch)?;

        if decoded != *database
            || updated[..span.start] != self.snapshot[..self.span.start]
            || updated[span.end..] != self.snapshot[self.span.end..]
        {
            return Err(StoreError::EncodeMismatch);
        }

        Ok(span)
    }

    fn newline(&self) -> Newline {
        let span = &self.snapshot[self.span.clone()];
        if span.windows(2).any(|pair| pair == b"\r\n") {
            Newline::Crlf
        } else if span.contains(&b'\n') {
            Newline::Lf
        } else {
            Newline::Crlf
        }
    }

    fn backup_path(&self) -> PathBuf {
        let mut name = self.path.file_name().unwrap_or_default().to_os_string();
        name.push(BACKUP_SUFFIX);
        self.path.with_file_name(name)
    }
}

fn database_span(source: &[u8]) -> Result<Range<usize>, LoadError> {
    let statements = lua::scan_statements(source).map_err(LoadError::Syntax)?;
    let mut found = None;

    for statement in statements {
        if &source[statement.name.clone()] == DATABASE_NAME {
            if found.is_some() {
                return Err(LoadError::DuplicateDatabase);
            }
            found = Some(statement.value);
        }
    }

    found.ok_or(LoadError::MissingDatabase)
}

fn replace(target: &Path, contents: &[u8]) -> io::Result<()> {
    let directory = target.parent().unwrap_or_else(|| Path::new("."));
    let (path, file) = create_temp(directory, target)?;

    if let Err(error) = write_all(file, contents).and_then(|()| fs::rename(&path, target)) {
        let _ = fs::remove_file(&path);
        return Err(error);
    }

    Ok(())
}

fn write_all(mut file: File, contents: &[u8]) -> io::Result<()> {
    file.write_all(contents)?;
    file.sync_all()
}

fn create_temp(directory: &Path, target: &Path) -> io::Result<(PathBuf, File)> {
    let stem = target.file_name().unwrap_or_default().to_os_string();

    for _ in 0..TEMP_ATTEMPTS {
        let mut bytes = [0_u8; 8];
        getrandom::getrandom(&mut bytes).map_err(|error| io::Error::other(error.to_string()))?;

        let mut name = stem.clone();
        name.push(format!(
            "{TEMP_PREFIX}{:016x}.tmp",
            u64::from_le_bytes(bytes)
        ));
        let path = directory.join(name);

        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => return Ok((path, file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
    }

    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not create a unique temporary file",
    ))
}

#[cfg(test)]
mod temp {
    use std::{
        env, fs,
        path::{Path, PathBuf},
        sync::atomic::{AtomicU64, Ordering},
    };

    static NEXT: AtomicU64 = AtomicU64::new(0);

    pub(super) struct Dir {
        path: PathBuf,
    }

    impl Dir {
        pub(super) fn new(label: &str) -> Self {
            let unique = NEXT.fetch_add(1, Ordering::Relaxed);
            let path =
                env::temp_dir().join(format!("arbitrage-{}-{label}-{unique}", std::process::id()));
            fs::create_dir_all(&path).expect("the temp directory should be creatable");
            Self { path }
        }

        pub(super) fn path(&self) -> &Path {
            &self.path
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Database, LoadError, SavedVariables, StoreError, StoreOutcome, codec, codec::Newline, lua,
        temp,
    };
    use arbitrage_shared::{Copper, DbKey, Faction, Timestamp};
    use std::{fs, path::PathBuf};

    const FIXTURE: &[u8] = include_bytes!("../../tests/fixtures/Arbitrage.lua");
    const DATABASE_MARKER: &[u8] = b"\r\nARBITRAGE_DATABASE = {";
    const RECIPES_MARKER: &[u8] = b"\r\nARBITRAGE_RECIPES = {";

    struct Account {
        directory: temp::Dir,
        path: PathBuf,
    }

    impl Account {
        fn new(label: &str, contents: &[u8]) -> Self {
            let directory = temp::Dir::new(label);
            let path = directory.path().join("Arbitrage.lua");
            fs::write(&path, contents).expect("the fixture copy should be writable");
            Self { directory, path }
        }

        fn from_fixture(label: &str) -> Self {
            Self::new(label, FIXTURE)
        }

        fn read(&self) -> Vec<u8> {
            fs::read(&self.path).expect("the target should be readable")
        }

        fn backup(&self) -> PathBuf {
            self.directory.path().join("Arbitrage.lua.companion.bak")
        }

        fn file_names(&self) -> Vec<String> {
            let mut names: Vec<String> = fs::read_dir(self.directory.path())
                .expect("the temp directory should be readable")
                .flatten()
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .collect();
            names.sort();
            names
        }
    }

    fn index_of(haystack: &[u8], needle: &[u8]) -> usize {
        haystack
            .windows(needle.len())
            .position(|window| window == needle)
            .expect("the marker should be present")
    }

    fn changed(database: &Database) -> Database {
        let mut changed = database.clone();
        changed.last_replicate_scan = Timestamp::new(1_800_000_000);
        changed
            .realms
            .get_mut("Test Realm")
            .expect("the fixture realm should decode")
            .markets
            .get_mut(&Faction::Alliance)
            .expect("the fixture market should decode")
            .latest_buyouts
            .insert(DbKey::new("2589"), Copper::new(4_242).unwrap());
        changed
    }

    #[test]
    fn the_fixture_uses_crlf_and_keeps_integer_scan_keys() {
        assert!(FIXTURE.starts_with(b"\r\n"));
        assert!(
            !FIXTURE
                .windows(2)
                .any(|pair| pair[0] != b'\r' && pair[1] == b'\n')
        );

        let account = Account::from_fixture("fixture-parse");
        let saved = SavedVariables::load(&account.path).expect("the fixture should load");
        let market = saved.database().realms["Test Realm"].markets[&Faction::Alliance].clone();
        let history = &market.items[&DbKey::new("2589")];

        assert_eq!(
            saved.database().last_replicate_scan,
            Timestamp::new(1_700_000_000)
        );
        assert_eq!(market.last_scan, Timestamp::new(1_700_000_100));
        assert_eq!(history.scans.len(), 2);
        assert_eq!(
            history.scans[&Timestamp::new(1_700_000_100).unwrap()],
            Copper::new(1_234).unwrap()
        );
    }

    #[test]
    fn parsing_encoding_and_parsing_again_yields_an_equal_database() {
        let account = Account::from_fixture("round-trip");
        let saved = SavedVariables::load(&account.path).expect("the fixture should load");

        for newline in [Newline::Lf, Newline::Crlf] {
            let encoded = codec::encode(saved.database(), newline);
            let value = lua::parse_value(&encoded).expect("the encoded database should parse");

            assert_eq!(&codec::decode(&value).unwrap(), saved.database());
        }
    }

    #[test]
    fn a_store_leaves_every_byte_outside_the_database_value_alone() {
        let account = Account::from_fixture("splice");
        let original = account.read();
        let head = index_of(&original, DATABASE_MARKER) + DATABASE_MARKER.len() - 1;
        let tail = index_of(&original, RECIPES_MARKER);

        let mut saved = SavedVariables::load(&account.path).expect("the fixture should load");
        let wanted = changed(saved.database());
        let outcome = saved.store(&wanted).expect("the store should succeed");

        let updated = account.read();
        assert_eq!(outcome, StoreOutcome::Written);
        assert_ne!(updated, original);
        assert_eq!(&updated[..head], &original[..head]);
        assert_eq!(
            &updated[index_of(&updated, RECIPES_MARKER)..],
            &original[tail..]
        );
    }

    #[test]
    fn a_real_change_backs_up_the_previous_bytes() {
        let account = Account::from_fixture("backup");
        let original = account.read();

        let mut saved = SavedVariables::load(&account.path).expect("the fixture should load");
        let wanted = changed(saved.database());
        saved.store(&wanted).expect("the store should succeed");

        let updated = account.read();
        assert_eq!(fs::read(account.backup()).unwrap(), original);
        assert_ne!(updated, original);
        assert!(
            !updated
                .windows(2)
                .any(|pair| pair[0] != b'\r' && pair[1] == b'\n'),
            "the encoder should inherit CRLF from the old database span"
        );
        assert_eq!(
            SavedVariables::load(&account.path)
                .expect("the rewritten file should load")
                .database(),
            &wanted
        );
        assert_eq!(
            account.file_names(),
            vec!["Arbitrage.lua", "Arbitrage.lua.companion.bak"]
        );
    }

    #[test]
    fn storing_the_same_database_again_changes_nothing() {
        let account = Account::from_fixture("unchanged");
        let mut saved = SavedVariables::load(&account.path).expect("the fixture should load");
        let wanted = changed(saved.database());
        saved.store(&wanted).expect("the store should succeed");

        fs::write(account.backup(), b"sentinel").expect("the backup should be writable");
        let written = account.read();

        let outcome = saved
            .store(&wanted)
            .expect("the second store should succeed");

        assert_eq!(outcome, StoreOutcome::Unchanged);
        assert_eq!(account.read(), written);
        assert_eq!(fs::read(account.backup()).unwrap(), b"sentinel");
    }

    #[test]
    fn a_file_changed_after_load_is_not_overwritten() {
        let account = Account::from_fixture("changed-on-disk");
        let mut saved = SavedVariables::load(&account.path).expect("the fixture should load");
        let wanted = changed(saved.database());

        let mut meddled = account.read();
        meddled.extend_from_slice(b"ARBITRAGE_EXTRA = 1\r\n");
        fs::write(&account.path, &meddled).expect("the target should be writable");

        assert!(matches!(
            saved.store(&wanted),
            Err(StoreError::ChangedOnDisk)
        ));
        assert_eq!(account.read(), meddled);
        assert_eq!(account.file_names(), vec!["Arbitrage.lua"]);
    }

    #[test]
    fn a_rejected_file_is_never_written_to() {
        let version_two = replace_in_fixture(b"[\"__version\"] = 1,", b"[\"__version\"] = 2,");
        let unknown_key = replace_in_fixture(
            b"[\"realms\"] = {",
            b"[\"extra\"] = 1,\r\n\t[\"realms\"] = {",
        );
        let float_price = replace_in_fixture(b"[\"2589\"] = 1200,", b"[\"2589\"] = 1200.5,");
        let duplicate = {
            let mut bytes = FIXTURE.to_vec();
            bytes.extend_from_slice(b"ARBITRAGE_DATABASE = {\r\n}\r\n");
            bytes
        };
        let historical =
            b"\r\nARBITRAGE_DATABASE = {\r\n\t[\"Test Realm\"] = {\r\n\t},\r\n}\r\n".to_vec();
        let malformed = replace_in_fixture(b"[\"realms\"] = {", b"[\"realms\"] = {{{,");

        let cases: Vec<(&str, Vec<u8>)> = vec![
            ("malformed", malformed),
            ("duplicate", duplicate),
            ("version-two", version_two),
            ("historical", historical),
            ("unknown-key", unknown_key),
            ("float-price", float_price),
        ];

        for (label, contents) in cases {
            let account = Account::new(label, &contents);
            let error = SavedVariables::load(&account.path)
                .err()
                .unwrap_or_else(|| panic!("{label} should not load"));

            assert!(
                !matches!(error, LoadError::Read(_)),
                "{label} should fail on content, not on reading"
            );
            assert_eq!(account.read(), contents, "{label} rewrote the target");
            assert_eq!(
                account.file_names(),
                vec!["Arbitrage.lua"],
                "{label} left a stray file"
            );
        }
    }

    fn replace_in_fixture(needle: &[u8], replacement: &[u8]) -> Vec<u8> {
        let at = index_of(FIXTURE, needle);
        let mut bytes = FIXTURE[..at].to_vec();
        bytes.extend_from_slice(replacement);
        bytes.extend_from_slice(&FIXTURE[at + needle.len()..]);
        bytes
    }
}

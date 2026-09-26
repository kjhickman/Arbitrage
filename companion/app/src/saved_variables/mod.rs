mod codec;
mod locate;
mod lua;

pub use locate::{FILE_NAME, LocateError, locate, product_roots};

use arbitrage_shared::Database;
use codec::DecodeError;
use std::{
    fmt,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    ops::Range,
    path::{Path, PathBuf},
};

const DATABASE_NAME: &[u8] = b"ARBITRAGE_DATABASE";
const IMPORT_PREFIX: &[u8] = b"ARBITRAGE_IMPORT = ";
const TEMP_PREFIX: &str = ".companion-";
const TEMP_ATTEMPTS: usize = 16;
const TOC_NAME: &str = "Arbitrage.toc";
const DATA_ADDON_NAME: &str = "Arbitrage_Data";
const DATA_TOC_NAME: &str = "Arbitrage_Data.toc";
const DATA_TOC: &[u8] = b"\
## Interface: 16001
## Title: Arbitrage Data
## Notes: Synced scan database loaded at startup
## Author: kjhickman

Database.lua
";

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
pub enum PublishError {
    NotFound,
    Write(io::Error),
}

impl fmt::Display for PublishError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound => write!(formatter, "The Arbitrage addon folder was not found."),
            Self::Write(error) => write!(formatter, "the import file is unwritable: {error}"),
        }
    }
}

/// Writes the combined database into the sibling `Arbitrage_Data` addon.
///
/// # Errors
///
/// Returns [`PublishError::NotFound`] when no installed addon TOC is found, or
/// [`PublishError::Write`] when the import file cannot be created or replaced.
pub fn publish_import(
    saved_variables: &Path,
    database: &Database,
    roots: &[PathBuf],
) -> Result<(), PublishError> {
    let addon = resolve_addon_directory(saved_variables, roots).ok_or(PublishError::NotFound)?;
    let addons = addon.parent().ok_or(PublishError::NotFound)?;
    let data_directory = addons.join(DATA_ADDON_NAME);
    fs::create_dir_all(&data_directory).map_err(PublishError::Write)?;
    let toc_path = data_directory.join(DATA_TOC_NAME);
    if !toc_path.is_file() {
        replace(&toc_path, DATA_TOC).map_err(PublishError::Write)?;
    }
    let path = data_directory.join("Database.lua");

    let mut contents = IMPORT_PREFIX.to_vec();
    contents.extend(codec::encode(database));
    contents.push(b'\n');

    if path.is_file() {
        let existing = fs::read(&path).map_err(PublishError::Write)?;
        if existing == contents {
            return Ok(());
        }
    }

    replace(&path, &contents).map_err(PublishError::Write)
}

fn resolve_addon_directory(saved_variables: &Path, roots: &[PathBuf]) -> Option<PathBuf> {
    if let Some(root) = product_root_from_saved_variables(saved_variables) {
        let addon = addon_directory(&root);
        if addon.join(TOC_NAME).is_file() {
            return Some(addon);
        }
    }

    roots.iter().find_map(|root| {
        let addon = addon_directory(root);
        addon.join(TOC_NAME).is_file().then_some(addon)
    })
}

fn addon_directory(root: &Path) -> PathBuf {
    root.join("Interface").join("AddOns").join("Arbitrage")
}

fn product_root_from_saved_variables(path: &Path) -> Option<PathBuf> {
    if path.file_name()? != FILE_NAME {
        return None;
    }

    let saved_variables = path.parent()?;
    if saved_variables.file_name()? != "SavedVariables" {
        return None;
    }

    let account = saved_variables.parent()?;
    let accounts = account.parent()?;
    if accounts.file_name()? != "Account" {
        return None;
    }

    let wtf = accounts.parent()?;
    if wtf.file_name()? != "WTF" {
        return None;
    }

    Some(wtf.parent()?.to_path_buf())
}

/// Reads the account's own database out of its `Arbitrage.lua`; the file is never written.
pub fn load(path: &Path) -> Result<Database, LoadError> {
    let source = fs::read(path).map_err(LoadError::Read)?;
    let span = database_span(&source)?;
    let value = lua::parse_value(&source[span]).map_err(LoadError::Syntax)?;
    codec::decode(&value).map_err(LoadError::Decode)
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
pub mod temp {
    use std::{
        env, fs,
        path::{Path, PathBuf},
        sync::atomic::{AtomicU64, Ordering},
    };

    static NEXT: AtomicU64 = AtomicU64::new(0);

    pub struct Dir {
        path: PathBuf,
    }

    impl Dir {
        pub fn new(label: &str) -> Self {
            let unique = NEXT.fetch_add(1, Ordering::Relaxed);
            let path =
                env::temp_dir().join(format!("arbitrage-{}-{label}-{unique}", std::process::id()));
            fs::create_dir_all(&path).expect("the temp directory should be creatable");
            Self { path }
        }

        pub fn path(&self) -> &Path {
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
    use super::{Database, LoadError, PublishError, codec, load, lua, publish_import, temp};
    use arbitrage_shared::{Copper, DbKey, Faction, ItemHistory, Market, Realm, Timestamp};
    use std::{collections::BTreeMap, fs, path::PathBuf};

    const FIXTURE: &[u8] = include_bytes!("../../tests/fixtures/Arbitrage.lua");

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

    #[test]
    fn the_crlf_fixture_loads_with_integer_scan_keys_and_market_meta() {
        assert!(FIXTURE.starts_with(b"\r\n"));
        assert!(
            !FIXTURE
                .windows(2)
                .any(|pair| pair[0] != b'\r' && pair[1] == b'\n')
        );

        let account = Account::from_fixture("fixture-parse");
        let database = load(&account.path).expect("the fixture should load");
        let realm = &database.realms["Test Realm"];
        let market = &realm.markets[&Faction::Alliance];
        let history = &market.items[&DbKey::new("2589")];

        assert_eq!(database.last_replicate_scan, Timestamp::new(1_700_000_000));
        assert_eq!(realm.region, 1);
        assert_eq!(market.last_scan, Timestamp::new(1_700_000_100));
        assert_eq!(market.last_played, Timestamp::new(1_700_000_050));
        assert_eq!(history.scans.len(), 2);
        assert_eq!(
            history.scans[&Timestamp::new(1_700_000_100).unwrap()],
            Copper::new(1_234).unwrap()
        );
    }

    #[test]
    fn parsing_encoding_and_parsing_again_yields_an_equal_database() {
        let account = Account::from_fixture("round-trip");
        let database = load(&account.path).expect("the fixture should load");

        let encoded = codec::encode(&database);
        let value = lua::parse_value(&encoded).expect("the encoded database should parse");

        assert_eq!(codec::decode(&value).unwrap(), database);
    }

    #[test]
    fn a_rejected_file_fails_on_content_and_is_left_alone() {
        let version_one = replace_in_fixture(b"[\"__version\"] = 2,", b"[\"__version\"] = 1,");
        let unknown_key = replace_in_fixture(
            b"[\"realms\"] = {",
            b"[\"extra\"] = 1,\r\n\t[\"realms\"] = {",
        );
        let float_price = replace_in_fixture(b"[\"2589\"] = 1200,", b"[\"2589\"] = 1200.5,");
        let missing_region = replace_in_fixture(b"[\"region\"] = 1,", b"");
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
            ("version-one", version_one),
            ("historical", historical),
            ("unknown-key", unknown_key),
            ("float-price", float_price),
            ("missing-region", missing_region),
        ];

        for (label, contents) in cases {
            let account = Account::new(label, &contents);
            let error = load(&account.path)
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

    fn publish_database() -> Database {
        Database {
            last_replicate_scan: None,
            realms: BTreeMap::from([(
                "Test Realm".to_owned(),
                Realm {
                    region: 1,
                    markets: BTreeMap::from([(
                        Faction::Alliance,
                        Market {
                            last_scan: Timestamp::new(1_000),
                            last_played: None,
                            items: BTreeMap::from([(
                                DbKey::new("2589"),
                                ItemHistory {
                                    scans: BTreeMap::from([(
                                        Timestamp::new(1_000).unwrap(),
                                        Copper::new(40).unwrap(),
                                    )]),
                                },
                            )]),
                            latest_buyouts: BTreeMap::new(),
                        },
                    )]),
                    vendor_prices: BTreeMap::new(),
                },
            )]),
        }
    }

    fn product_with_addon(label: &str) -> (temp::Dir, PathBuf, PathBuf) {
        let root = temp::Dir::new(label);
        let saved_variables = root
            .path()
            .join("WTF")
            .join("Account")
            .join("ACCT")
            .join("SavedVariables")
            .join("Arbitrage.lua");
        fs::create_dir_all(saved_variables.parent().unwrap())
            .expect("the saved variables directory should be creatable");
        fs::write(&saved_variables, b"\nARBITRAGE_DATABASE = {\n}\n")
            .expect("the saved variables stub should be writable");

        let addon = root
            .path()
            .join("Interface")
            .join("AddOns")
            .join("Arbitrage");
        fs::create_dir_all(&addon).expect("the addon directory should be creatable");
        fs::write(addon.join("Arbitrage.toc"), b"## Interface: 16001\n")
            .expect("the toc should be writable");
        let import_path = addon
            .parent()
            .expect("AddOns should contain the addon")
            .join("Arbitrage_Data")
            .join("Database.lua");

        (root, saved_variables, import_path)
    }

    fn decode_import(path: &PathBuf) -> Database {
        let bytes = fs::read(path).expect("the import file should be readable");
        assert!(
            bytes.starts_with(b"ARBITRAGE_IMPORT = "),
            "the import file should start with ARBITRAGE_IMPORT = "
        );
        let table = &bytes[b"ARBITRAGE_IMPORT = ".len()..];
        let value = lua::parse_value(table).expect("the import table should parse");
        codec::decode(&value).expect("the import table should decode")
    }

    #[test]
    fn publish_import_writes_the_merged_database_next_to_the_toc() {
        let (root, saved_variables, import_path) = product_with_addon("publish-write");
        let database = publish_database();

        publish_import(&saved_variables, &database, &[])
            .expect("publish should find the addon beside the saved variables");

        assert_eq!(
            fs::read(import_path.with_file_name("Arbitrage_Data.toc"))
                .expect("the data addon toc should be written"),
            super::DATA_TOC
        );
        let decoded = decode_import(&import_path);
        assert_eq!(decoded, database);
        assert_eq!(
            decoded.realms["Test Realm"].markets[&Faction::Alliance].items[&DbKey::new("2589")]
                .scans[&Timestamp::new(1_000).unwrap()],
            Copper::new(40).unwrap()
        );
        let _ = root;
    }

    #[test]
    fn publish_import_skips_a_rewrite_when_the_bytes_match() {
        let (root, saved_variables, import_path) = product_with_addon("publish-unchanged");
        let database = publish_database();

        publish_import(&saved_variables, &database, &[]).expect("the first publish should write");
        let first = fs::read(&import_path).expect("the import file should be readable");

        publish_import(&saved_variables, &database, &[])
            .expect("the second publish should succeed");

        assert_eq!(
            fs::read(&import_path).expect("the import file should be readable"),
            first
        );
        let _ = root;
    }

    #[test]
    fn publish_import_searches_roots_when_the_saved_path_is_outside_the_product() {
        let (root, _, import_path) = product_with_addon("publish-roots");
        let outside = temp::Dir::new("publish-outside");
        let saved_variables = outside.path().join("Arbitrage.lua");
        fs::write(&saved_variables, b"\nARBITRAGE_DATABASE = {\n}\n")
            .expect("the outside saved variables should be writable");
        let database = publish_database();

        publish_import(&saved_variables, &database, &[root.path().to_path_buf()])
            .expect("publish should find the toc through roots");

        assert_eq!(decode_import(&import_path), database);
    }

    #[test]
    fn publish_import_errors_when_no_toc_exists() {
        let root = temp::Dir::new("publish-missing");
        let saved_variables = root
            .path()
            .join("WTF")
            .join("Account")
            .join("ACCT")
            .join("SavedVariables")
            .join("Arbitrage.lua");
        fs::create_dir_all(saved_variables.parent().unwrap())
            .expect("the saved variables directory should be creatable");
        fs::write(&saved_variables, b"\nARBITRAGE_DATABASE = {\n}\n")
            .expect("the saved variables stub should be writable");

        let error = publish_import(
            &saved_variables,
            &publish_database(),
            &[root.path().to_path_buf()],
        )
        .expect_err("publish should fail without a toc");

        assert_eq!(
            error.to_string(),
            "The Arbitrage addon folder was not found."
        );
        assert!(
            !root
                .path()
                .join("Interface")
                .join("AddOns")
                .join("Arbitrage_Data")
                .exists()
        );
        assert!(matches!(error, PublishError::NotFound));
    }
}

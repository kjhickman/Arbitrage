mod codec;
mod locate;
mod lua;

pub use locate::{FILE_NAME, LocateError, locate, product_roots};

use arbitrage_shared::{Database, Import, ItemId};
use codec::DecodeError;
use std::{
    collections::BTreeSet,
    fmt,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    ops::Range,
    path::{Path, PathBuf},
};

const DATABASE_NAME: &[u8] = b"ARBITRAGE_DATABASE";
const GREY_ITEMS_NAME: &[u8] = b"ARBITRAGE_GREY_ITEMS";
const TEMP_PREFIX: &str = ".companion-";
const TEMP_ATTEMPTS: usize = 16;
const TOC_NAME: &str = "Arbitrage.toc";
const DATA_ADDON_NAME: &str = "Arbitrage_Data";
const DATA_TOC_NAME: &str = "Arbitrage_Data.toc";
const DATA_TOC: &[u8] = b"\
## Interface: 16001
## Title: Arbitrage Data
## Notes: Synced scan database, loaded at login or /reload
## Author: kjhickman
## IconTexture: Interface\\AddOns\\Arbitrage\\media\\icon

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

/// Writes the combined import into the sibling `Arbitrage_Data` addon, stamped with when it was
/// synced.
///
/// # Errors
///
/// Returns [`PublishError::NotFound`] when no installed addon TOC is found, or
/// [`PublishError::Write`] when the import file cannot be created or replaced.
pub fn publish_import(
    saved_variables: &Path,
    import: &Import,
    roots: &[PathBuf],
) -> Result<(), PublishError> {
    let addon = resolve_addon_directory(saved_variables, roots).ok_or(PublishError::NotFound)?;
    let addons = addon.parent().ok_or(PublishError::NotFound)?;
    let data_directory = addons.join(DATA_ADDON_NAME);
    fs::create_dir_all(&data_directory).map_err(PublishError::Write)?;
    let toc_path = data_directory.join(DATA_TOC_NAME);
    if fs::read(&toc_path).ok().as_deref() != Some(DATA_TOC) {
        replace(&toc_path, DATA_TOC).map_err(PublishError::Write)?;
    }
    let path = data_directory.join("Database.lua");

    replace(&path, &codec::encode_import(import)).map_err(PublishError::Write)
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

/// What the companion reads of the account's `Arbitrage.lua`.
#[derive(Debug)]
pub struct Saved {
    pub database: Database,
    /// Items the addon has seen to be grey, which the import leaves out.
    pub grey_items: BTreeSet<ItemId>,
}

/// Reads the account's own database out of its `Arbitrage.lua`; the file is never written.
pub fn load(path: &Path) -> Result<Saved, LoadError> {
    let source = fs::read(path).map_err(LoadError::Read)?;
    let spans = statement_spans(&source)?;
    let value = lua::parse_value(&source[spans.database]).map_err(LoadError::Syntax)?;
    let database = codec::decode(&value).map_err(LoadError::Decode)?;
    drop(value);
    let grey_items = spans
        .grey_items
        .and_then(|span| lua::parse_value(&source[span]).ok())
        .map(|value| codec::decode_grey_items(&value))
        .unwrap_or_default();
    Ok(Saved {
        database,
        grey_items,
    })
}

struct Spans {
    database: Range<usize>,
    grey_items: Option<Range<usize>>,
}

fn statement_spans(source: &[u8]) -> Result<Spans, LoadError> {
    let statements = lua::scan_statements(source).map_err(LoadError::Syntax)?;
    let mut database = None;
    let mut grey_items = None;

    for statement in statements {
        let name = &source[statement.name.clone()];
        if name == DATABASE_NAME {
            if database.is_some() {
                return Err(LoadError::DuplicateDatabase);
            }
            database = Some(statement.value);
        } else if name == GREY_ITEMS_NAME {
            grey_items = Some(statement.value);
        }
    }

    Ok(Spans {
        database: database.ok_or(LoadError::MissingDatabase)?,
        grey_items,
    })
}

/// Writes `contents` to `target` through a temporary file in the same folder, so a reader never
/// sees it half written.
pub fn replace(target: &Path, contents: &[u8]) -> io::Result<()> {
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
    use super::{LoadError, PublishError, load, publish_import, temp};
    use arbitrage_shared::{
        Copper, DayTotals, DbKey, Faction, Import, ImportItem, ImportMarket, ImportRealm, ItemId,
        Scan, Timestamp,
    };
    use std::{
        collections::{BTreeMap, BTreeSet},
        fs,
        path::PathBuf,
    };

    const FIXTURE: &[u8] = include_bytes!("../../tests/fixtures/Arbitrage.lua");

    struct Account {
        _directory: temp::Dir,
        path: PathBuf,
    }

    impl Account {
        fn new(label: &str, contents: &[u8]) -> Self {
            let directory = temp::Dir::new(label);
            let path = directory.path().join("Arbitrage.lua");
            fs::write(&path, contents).expect("the fixture copy should be writable");
            Self {
                _directory: directory,
                path,
            }
        }

        fn from_fixture(label: &str) -> Self {
            Self::new(label, FIXTURE)
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
        let saved = load(&account.path).expect("the fixture should load");
        let database = &saved.database;
        let realm = &database.realms["Test Realm"];
        let market = &realm.markets[&Faction::Alliance];
        let copper = |value| Copper::new(value).unwrap();

        assert_eq!(database.last_replicate_scan, Timestamp::new(1_700_000_000));
        assert_eq!(realm.region, 1);
        assert_eq!(market.last_played, Timestamp::new(1_700_000_050));
        assert_eq!(
            market.scans,
            vec![
                Scan {
                    at: Timestamp::new(1_699_913_700).unwrap(),
                    market_values: BTreeMap::from([(DbKey::new("2589"), copper(1_300))]),
                    ..Scan::default()
                },
                Scan {
                    at: Timestamp::new(1_700_000_100).unwrap(),
                    market_values: BTreeMap::from([
                        (DbKey::new("2589"), copper(1_234)),
                        (DbKey::new("equip:12345:1234"), copper(50_000)),
                    ]),
                    buyouts: Some(BTreeMap::from([(DbKey::new("2589"), copper(1_200))])),
                    ..Scan::default()
                },
            ]
        );
        assert_eq!(
            saved.grey_items,
            BTreeSet::from([ItemId::new(3_300).unwrap()])
        );
    }

    #[test]
    fn a_second_database_assignment_is_rejected() {
        let mut duplicate = FIXTURE.to_vec();
        duplicate.extend_from_slice(b"ARBITRAGE_DATABASE = {\r\n}\r\n");
        let account = Account::new("duplicate", &duplicate);

        assert!(matches!(
            load(&account.path),
            Err(LoadError::DuplicateDatabase)
        ));
    }

    #[test]
    fn a_malformed_file_is_rejected() {
        let malformed = replace_in_fixture(b"[\"realms\"] = {", b"[\"realms\"] = {{{,");
        let account = Account::new("malformed", &malformed);

        assert!(matches!(load(&account.path), Err(LoadError::Syntax(_))));
    }

    fn replace_in_fixture(needle: &[u8], replacement: &[u8]) -> Vec<u8> {
        let at = index_of(FIXTURE, needle);
        let mut bytes = FIXTURE[..at].to_vec();
        bytes.extend_from_slice(replacement);
        bytes.extend_from_slice(&FIXTURE[at + needle.len()..]);
        bytes
    }

    fn publish_import_data() -> Import {
        let at = Timestamp::new(1_000).unwrap();
        Import {
            realms: BTreeMap::from([(
                "Test Realm".to_owned(),
                ImportRealm {
                    region: 1,
                    markets: BTreeMap::from([(
                        Faction::Alliance,
                        ImportMarket {
                            last_scan: Some(at),
                            item_buyouts: None,
                            variant_buyouts: None,
                            scans: BTreeSet::from([at]),
                            quick_scans: BTreeSet::new(),
                            items: BTreeMap::from([(
                                DbKey::new("2589"),
                                ImportItem {
                                    latest: at,
                                    days: BTreeMap::from([(
                                        0,
                                        DayTotals {
                                            market_value: 40 * 1024 + 1,
                                            ..DayTotals::default()
                                        },
                                    )]),
                                },
                            )]),
                        },
                    )]),
                    vendor_prices: BTreeMap::new(),
                },
            )]),
            regions: BTreeMap::new(),
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

    const EXPECTED_TOC: &[u8] = b"\
## Interface: 16001
## Title: Arbitrage Data
## Notes: Synced scan database, loaded at login or /reload
## Author: kjhickman
## IconTexture: Interface\\AddOns\\Arbitrage\\media\\icon

Database.lua
";

    const EXPECTED_DATABASE: &[u8] = concat!(
        "ARBITRAGE_IMPORT = {\n",
        "[\"__version\"] = 4,\n",
        "[\"meta\"] = {\n},\n",
        "[\"realms\"] = {\n",
        "[\"Test Realm\"] = {\n",
        "[\"region\"] = 1,\n",
        "[\"markets\"] = {\n",
        "[\"Alliance\"] = {\n",
        "[\"meta\"] = {\n[\"lastScan\"] = 1000,\n},\n",
        "[\"scans\"] = {\n1000,\n},\n",
        "[\"quickScans\"] = {\n},\n",
        "[\"items\"] = {\n},\n",
        "[\"buyouts\"] = {\n},\n",
        "},\n",
        "},\n",
        "[\"vendorPrices\"] = {\n},\n",
        "},\n",
        "},\n",
        "[\"regions\"] = {\n},\n",
        "};\n",
        "(function(t)\n",
        "t[\"2589\"] = {1000,0,40961,0,0,0}\n",
        "end)(ARBITRAGE_IMPORT[\"realms\"][\"Test Realm\"][\"markets\"][\"Alliance\"][\"items\"]);\n",
    )
    .as_bytes();

    #[test]
    fn publish_import_writes_the_merged_database_next_to_the_toc() {
        let (root, saved_variables, import_path) = product_with_addon("publish-write");
        let import = publish_import_data();

        publish_import(&saved_variables, &import, &[])
            .expect("publish should find the addon beside the saved variables");

        assert_eq!(
            fs::read(import_path.with_file_name("Arbitrage_Data.toc"))
                .expect("the data addon toc should be written"),
            EXPECTED_TOC
        );
        assert_eq!(
            fs::read(&import_path).expect("the import file should be readable"),
            EXPECTED_DATABASE
        );
        let _ = root;
    }

    #[test]
    fn publish_import_adds_the_arbitrage_icon_to_an_existing_data_addon() {
        let (_root, saved_variables, import_path) = product_with_addon("publish-icon");
        let toc_path = import_path.with_file_name("Arbitrage_Data.toc");
        fs::create_dir_all(toc_path.parent().unwrap()).unwrap();
        fs::write(&toc_path, "## Title: Arbitrage Data\n\nDatabase.lua\n").unwrap();

        publish_import(&saved_variables, &publish_import_data(), &[])
            .expect("publish should update the existing data addon");

        let toc = fs::read_to_string(toc_path).expect("the updated toc should be readable");
        assert!(
            toc.lines()
                .any(|line| line == r"## IconTexture: Interface\AddOns\Arbitrage\media\icon")
        );
    }

    #[test]
    fn publish_import_searches_roots_when_the_saved_path_is_outside_the_product() {
        let (root, _, import_path) = product_with_addon("publish-roots");
        let outside = temp::Dir::new("publish-outside");
        let saved_variables = outside.path().join("Arbitrage.lua");
        fs::write(&saved_variables, b"\nARBITRAGE_DATABASE = {\n}\n")
            .expect("the outside saved variables should be writable");
        let import = publish_import_data();

        publish_import(&saved_variables, &import, &[root.path().to_path_buf()])
            .expect("publish should find the toc through roots");

        assert_eq!(
            fs::read(&import_path).expect("the import file should be readable"),
            EXPECTED_DATABASE
        );
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
            &publish_import_data(),
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

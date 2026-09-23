use std::{collections::BTreeMap, fmt};

use arbitrage_shared::{
    Copper, Database, DbKey, Faction, ItemHistory, ItemId, Market, Realm, SCHEMA_VERSION, Timestamp,
};

use super::lua::{Key, Table, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Newline {
    Lf,
    Crlf,
}

impl Newline {
    const fn as_bytes(self) -> &'static [u8] {
        match self {
            Self::Lf => b"\n",
            Self::Crlf => b"\r\n",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    UnsupportedVersion(Option<i64>),
    Schema(String),
}

impl fmt::Display for DecodeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedVersion(Some(version)) => {
                write!(
                    formatter,
                    "the saved database is version {version}, not {SCHEMA_VERSION}"
                )
            }
            Self::UnsupportedVersion(None) => {
                write!(formatter, "the saved database has no version")
            }
            Self::Schema(detail) => write!(formatter, "the saved database is malformed: {detail}"),
        }
    }
}

pub fn decode(value: &Value) -> Result<Database, DecodeError> {
    let root = as_table(value, "the database")?;

    match find(root, "__version") {
        None => return Err(DecodeError::UnsupportedVersion(None)),
        Some(Value::Integer(version)) if *version == i64::from(SCHEMA_VERSION) => {}
        Some(Value::Integer(version)) => {
            return Err(DecodeError::UnsupportedVersion(Some(*version)));
        }
        Some(_) => return Err(schema("the database", "__version is not an integer")),
    }

    let mut meta = None;
    let mut realms = None;
    for (key, entry) in root.entries() {
        match string_key(key) {
            Some("__version") => {}
            Some("meta") => meta = Some(entry),
            Some("realms") => realms = Some(entry),
            _ => return Err(unknown_key(key, "the database")),
        }
    }

    Ok(Database {
        last_replicate_scan: decode_root_meta(required(meta, "meta", "the database")?)?,
        realms: decode_realms(required(realms, "realms", "the database")?)?,
    })
}

pub fn encode(database: &Database, newline: Newline) -> Vec<u8> {
    let mut writer = Writer {
        out: Vec::new(),
        newline: newline.as_bytes(),
    };

    writer.begin();

    writer.string_key("__version");
    writer.signed(i64::from(SCHEMA_VERSION));
    writer.end_entry();

    writer.string_key("meta");
    writer.begin();
    if let Some(last_replicate_scan) = database.last_replicate_scan {
        writer.string_key("lastReplicateScan");
        writer.unsigned(last_replicate_scan.get());
        writer.end_entry();
    }
    writer.end();
    writer.end_entry();

    writer.string_key("realms");
    writer.begin();
    for (name, realm) in &database.realms {
        writer.string_key(name);
        write_realm(&mut writer, realm);
        writer.end_entry();
    }
    writer.end();
    writer.end_entry();

    writer.end();
    writer.out
}

fn decode_root_meta(value: &Value) -> Result<Option<Timestamp>, DecodeError> {
    let meta = as_table(value, "the database meta")?;
    let mut last_replicate_scan = None;

    for (key, entry) in meta.entries() {
        match string_key(key) {
            Some("lastReplicateScan") => {
                last_replicate_scan = Some(timestamp(entry, "lastReplicateScan")?);
            }
            _ => return Err(unknown_key(key, "the database meta")),
        }
    }

    Ok(last_replicate_scan)
}

fn decode_realms(value: &Value) -> Result<BTreeMap<String, Realm>, DecodeError> {
    let table = as_table(value, "realms")?;
    let mut realms = BTreeMap::new();

    for (key, entry) in table.entries() {
        let name = string_key(key).ok_or_else(|| unknown_key(key, "realms"))?;
        realms.insert(name.to_owned(), decode_realm(entry, name)?);
    }

    Ok(realms)
}

fn decode_realm(value: &Value, name: &str) -> Result<Realm, DecodeError> {
    let what = format!("realm {name}");
    let table = as_table(value, &what)?;
    let mut markets = None;
    let mut vendor_prices = None;

    for (key, entry) in table.entries() {
        match string_key(key) {
            Some("markets") => markets = Some(entry),
            Some("vendorPrices") => vendor_prices = Some(entry),
            _ => return Err(unknown_key(key, &what)),
        }
    }

    Ok(Realm {
        markets: decode_markets(required(markets, "markets", &what)?)?,
        vendor_prices: vendor_prices.map_or_else(|| Ok(BTreeMap::new()), decode_vendor_prices)?,
    })
}

fn decode_markets(value: &Value) -> Result<BTreeMap<Faction, Market>, DecodeError> {
    let table = as_table(value, "markets")?;
    let mut markets = BTreeMap::new();

    for (key, entry) in table.entries() {
        let faction = string_key(key)
            .and_then(Faction::from_name)
            .ok_or_else(|| unknown_key(key, "markets"))?;
        markets.insert(faction, decode_market(entry, faction)?);
    }

    Ok(markets)
}

fn decode_market(value: &Value, faction: Faction) -> Result<Market, DecodeError> {
    let what = format!("the {} market", faction.name());
    let table = as_table(value, &what)?;
    let mut meta = None;
    let mut items = None;
    let mut latest_buyouts = None;

    for (key, entry) in table.entries() {
        match string_key(key) {
            Some("meta") => meta = Some(entry),
            Some("items") => items = Some(entry),
            Some("latestBuyouts") => latest_buyouts = Some(entry),
            _ => return Err(unknown_key(key, &what)),
        }
    }

    Ok(Market {
        last_scan: decode_market_meta(required(meta, "meta", &what)?, &what)?,
        items: items.map_or_else(|| Ok(BTreeMap::new()), decode_items)?,
        latest_buyouts: latest_buyouts.map_or_else(|| Ok(BTreeMap::new()), decode_buyouts)?,
    })
}

fn decode_market_meta(value: &Value, what: &str) -> Result<Option<Timestamp>, DecodeError> {
    let meta = as_table(value, what)?;
    let mut last_scan = None;

    for (key, entry) in meta.entries() {
        match string_key(key) {
            Some("lastScan") => last_scan = Some(timestamp(entry, "lastScan")?),
            _ => return Err(unknown_key(key, what)),
        }
    }

    Ok(last_scan)
}

fn decode_items(value: &Value) -> Result<BTreeMap<DbKey, ItemHistory>, DecodeError> {
    let table = as_table(value, "items")?;
    let mut items = BTreeMap::new();

    for (key, entry) in table.entries() {
        let db_key = string_key(key).ok_or_else(|| unknown_key(key, "items"))?;
        items.insert(DbKey::new(db_key), decode_item(entry, db_key)?);
    }

    Ok(items)
}

fn decode_item(value: &Value, db_key: &str) -> Result<ItemHistory, DecodeError> {
    let what = format!("item {db_key}");
    let table = as_table(value, &what)?;
    let mut scans = None;

    for (key, entry) in table.entries() {
        match string_key(key) {
            Some("scans") => scans = Some(entry),
            _ => return Err(unknown_key(key, &what)),
        }
    }

    let table = as_table(required(scans, "scans", &what)?, &what)?;
    let mut history = BTreeMap::new();
    for (key, entry) in table.entries() {
        let Key::Integer(seconds) = key else {
            return Err(schema(&what, "a scan key is not an integer"));
        };
        let at = u64::try_from(*seconds)
            .ok()
            .and_then(Timestamp::new)
            .ok_or_else(|| schema(&what, "a scan key is out of range"))?;
        history.insert(at, copper(entry, &what)?);
    }

    Ok(ItemHistory { scans: history })
}

fn decode_buyouts(value: &Value) -> Result<BTreeMap<DbKey, Copper>, DecodeError> {
    let table = as_table(value, "latestBuyouts")?;
    let mut buyouts = BTreeMap::new();

    for (key, entry) in table.entries() {
        let db_key = string_key(key).ok_or_else(|| unknown_key(key, "latestBuyouts"))?;
        buyouts.insert(DbKey::new(db_key), copper(entry, "latestBuyouts")?);
    }

    Ok(buyouts)
}

fn decode_vendor_prices(
    value: &Value,
) -> Result<BTreeMap<String, BTreeMap<ItemId, Copper>>, DecodeError> {
    let table = as_table(value, "vendorPrices")?;
    let mut factions = BTreeMap::new();

    for (key, entry) in table.entries() {
        let faction = string_key(key).ok_or_else(|| unknown_key(key, "vendorPrices"))?;
        let what = format!("vendor prices for {faction}");
        let prices = as_table(entry, &what)?;
        let mut by_item = BTreeMap::new();

        for (item_key, price) in prices.entries() {
            by_item.insert(item_id(item_key, &what)?, copper(price, &what)?);
        }

        factions.insert(faction.to_owned(), by_item);
    }

    Ok(factions)
}

fn item_id(key: &Key, what: &str) -> Result<ItemId, DecodeError> {
    let text = string_key(key).ok_or_else(|| unknown_key(key, what))?;
    let value: u64 = text
        .parse()
        .map_err(|_| schema(what, "an item key is not a number"))?;

    // The encoder rewrites the key from the number, so only a canonical spelling round-trips.
    if value.to_string() != text {
        return Err(schema(what, "an item key is not written as a plain number"));
    }

    ItemId::new(value).ok_or_else(|| schema(what, "an item key is out of range"))
}

fn timestamp(value: &Value, what: &str) -> Result<Timestamp, DecodeError> {
    exact(value)
        .and_then(Timestamp::new)
        .ok_or_else(|| schema(what, "the value is not an exact non-negative integer"))
}

fn copper(value: &Value, what: &str) -> Result<Copper, DecodeError> {
    exact(value)
        .and_then(Copper::new)
        .ok_or_else(|| schema(what, "a price is not an exact non-negative integer"))
}

fn exact(value: &Value) -> Option<u64> {
    match value {
        Value::Integer(number) => u64::try_from(*number).ok(),
        _ => None,
    }
}

fn as_table<'a>(value: &'a Value, what: &str) -> Result<&'a Table, DecodeError> {
    match value {
        Value::Table(table) => Ok(table),
        _ => Err(schema(what, "the value is not a table")),
    }
}

fn find<'a>(table: &'a Table, name: &str) -> Option<&'a Value> {
    table
        .entries()
        .find(|(key, _)| string_key(key) == Some(name))
        .map(|(_, value)| value)
}

fn required<'a>(
    value: Option<&'a Value>,
    name: &str,
    what: &str,
) -> Result<&'a Value, DecodeError> {
    value.ok_or_else(|| schema(what, &format!("{name} is missing")))
}

fn string_key(key: &Key) -> Option<&str> {
    match key {
        Key::String(text) => str::from_utf8(text).ok(),
        Key::Integer(_) => None,
    }
}

fn unknown_key(key: &Key, what: &str) -> DecodeError {
    let label = match key {
        Key::Integer(index) => index.to_string(),
        Key::String(text) => String::from_utf8_lossy(text).into_owned(),
    };
    schema(what, &format!("{label} is not a known key"))
}

fn schema(what: &str, detail: &str) -> DecodeError {
    DecodeError::Schema(format!("{what}: {detail}"))
}

fn write_realm(writer: &mut Writer, realm: &Realm) {
    writer.begin();

    writer.string_key("markets");
    writer.begin();
    for (faction, market) in &realm.markets {
        writer.string_key(faction.name());
        write_market(writer, market);
        writer.end_entry();
    }
    writer.end();
    writer.end_entry();

    writer.string_key("vendorPrices");
    writer.begin();
    for (faction, prices) in &realm.vendor_prices {
        writer.string_key(faction);
        writer.begin();
        for (item, price) in prices {
            writer.string_key(&item.get().to_string());
            writer.unsigned(price.get());
            writer.end_entry();
        }
        writer.end();
        writer.end_entry();
    }
    writer.end();
    writer.end_entry();

    writer.end();
}

fn write_market(writer: &mut Writer, market: &Market) {
    writer.begin();

    writer.string_key("meta");
    writer.begin();
    if let Some(last_scan) = market.last_scan {
        writer.string_key("lastScan");
        writer.unsigned(last_scan.get());
        writer.end_entry();
    }
    writer.end();
    writer.end_entry();

    writer.string_key("items");
    writer.begin();
    for (db_key, history) in &market.items {
        writer.string_key(db_key.as_str());
        writer.begin();
        writer.string_key("scans");
        writer.begin();
        for (at, value) in &history.scans {
            writer.integer_key(at.get());
            writer.unsigned(value.get());
            writer.end_entry();
        }
        writer.end();
        writer.end_entry();
        writer.end();
        writer.end_entry();
    }
    writer.end();
    writer.end_entry();

    writer.string_key("latestBuyouts");
    writer.begin();
    for (db_key, price) in &market.latest_buyouts {
        writer.string_key(db_key.as_str());
        writer.unsigned(price.get());
        writer.end_entry();
    }
    writer.end();
    writer.end_entry();

    writer.end();
}

struct Writer {
    out: Vec<u8>,
    newline: &'static [u8],
}

impl Writer {
    fn begin(&mut self) {
        self.out.push(b'{');
        self.out.extend_from_slice(self.newline);
    }

    fn end(&mut self) {
        self.out.push(b'}');
    }

    fn end_entry(&mut self) {
        self.out.push(b',');
        self.out.extend_from_slice(self.newline);
    }

    fn string_key(&mut self, key: &str) {
        self.out.push(b'[');
        write_quoted(&mut self.out, key.as_bytes());
        self.out.extend_from_slice(b"] = ");
    }

    fn integer_key(&mut self, key: u64) {
        self.out.push(b'[');
        self.unsigned(key);
        self.out.extend_from_slice(b"] = ");
    }

    fn unsigned(&mut self, value: u64) {
        self.out.extend_from_slice(value.to_string().as_bytes());
    }

    fn signed(&mut self, value: i64) {
        self.out.extend_from_slice(value.to_string().as_bytes());
    }
}

fn write_quoted(out: &mut Vec<u8>, text: &[u8]) {
    out.push(b'"');

    for &byte in text {
        match byte {
            b'"' => out.extend_from_slice(b"\\\""),
            b'\\' => out.extend_from_slice(b"\\\\"),
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            byte if byte < 0x20 || byte == 0x7f => {
                out.extend_from_slice(format!("\\{byte:03}").as_bytes());
            }
            byte => out.push(byte),
        }
    }

    out.push(b'"');
}

#[cfg(test)]
mod tests {
    use super::{
        Copper, Database, DbKey, DecodeError, Faction, ItemHistory, Market, Newline, Realm,
        Timestamp, decode, encode,
    };
    use crate::saved_variables::lua::parse_value;
    use std::collections::BTreeMap;

    fn decode_source(source: &[u8]) -> Result<Database, DecodeError> {
        decode(&parse_value(source).expect("the fixture source should parse"))
    }

    fn sample() -> Database {
        let mut scans = BTreeMap::new();
        scans.insert(
            Timestamp::new(1_700_000_100).unwrap(),
            Copper::new(1_234).unwrap(),
        );

        let mut items = BTreeMap::new();
        items.insert(DbKey::new("2589"), ItemHistory { scans });

        let mut markets = BTreeMap::new();
        markets.insert(
            Faction::Alliance,
            Market {
                last_scan: Timestamp::new(1_700_000_100),
                items,
                latest_buyouts: BTreeMap::new(),
            },
        );

        let mut realms = BTreeMap::new();
        realms.insert(
            "Test Realm".to_owned(),
            Realm {
                markets,
                vendor_prices: BTreeMap::new(),
            },
        );

        Database {
            last_replicate_scan: Timestamp::new(1_700_000_000),
            realms,
        }
    }

    #[test]
    fn encodes_and_decodes_back_to_an_equal_database() {
        let database = sample();

        for newline in [Newline::Lf, Newline::Crlf] {
            let encoded = encode(&database, newline);
            assert_eq!(decode_source(&encoded).unwrap(), database);
        }
    }

    #[test]
    fn writes_the_version_the_encoder_owns() {
        let encoded = encode(&Database::default(), Newline::Lf);

        assert_eq!(
            String::from_utf8(encoded).unwrap(),
            "{\n[\"__version\"] = 1,\n[\"meta\"] = {\n},\n[\"realms\"] = {\n},\n}"
        );
    }

    #[test]
    fn rejects_a_future_version() {
        let source = b"{\n[\"__version\"] = 2,\n[\"meta\"] = {\n},\n[\"realms\"] = {\n},\n}";

        assert_eq!(
            decode_source(source),
            Err(DecodeError::UnsupportedVersion(Some(2)))
        );
    }

    #[test]
    fn rejects_a_historical_root_level_realm_map() {
        let source = b"{\n[\"Test Realm\"] = {\n[\"markets\"] = {\n},\n},\n}";

        assert_eq!(
            decode_source(source),
            Err(DecodeError::UnsupportedVersion(None))
        );
    }

    #[test]
    fn rejects_an_unknown_key() {
        let source =
            b"{\n[\"__version\"] = 1,\n[\"meta\"] = {\n},\n[\"realms\"] = {\n},\n[\"extra\"] = 1,\n}";

        assert!(matches!(decode_source(source), Err(DecodeError::Schema(_))));
    }

    #[test]
    fn rejects_a_float_price() {
        let source = b"{\n[\"__version\"] = 1,\n[\"meta\"] = {\n},\n[\"realms\"] = {\n[\"Test Realm\"] = {\n[\"markets\"] = {\n[\"Alliance\"] = {\n[\"meta\"] = {\n},\n[\"latestBuyouts\"] = {\n[\"2589\"] = 12.5,\n},\n},\n},\n},\n},\n}";

        assert!(matches!(decode_source(source), Err(DecodeError::Schema(_))));
    }

    #[test]
    fn rejects_a_string_scan_key() {
        let source = b"{\n[\"__version\"] = 1,\n[\"meta\"] = {\n},\n[\"realms\"] = {\n[\"Test Realm\"] = {\n[\"markets\"] = {\n[\"Alliance\"] = {\n[\"meta\"] = {\n},\n[\"items\"] = {\n[\"2589\"] = {\n[\"scans\"] = {\n[\"1700000100\"] = 12,\n},\n},\n},\n},\n},\n},\n},\n}";

        assert!(matches!(decode_source(source), Err(DecodeError::Schema(_))));
    }

    #[test]
    fn rejects_a_price_past_the_exact_integer_limit() {
        let source = b"{\n[\"__version\"] = 1,\n[\"meta\"] = {\n},\n[\"realms\"] = {\n[\"Test Realm\"] = {\n[\"markets\"] = {\n[\"Alliance\"] = {\n[\"meta\"] = {\n},\n[\"latestBuyouts\"] = {\n[\"2589\"] = 9007199254740993,\n},\n},\n},\n},\n},\n}";

        assert!(matches!(decode_source(source), Err(DecodeError::Schema(_))));
    }
}

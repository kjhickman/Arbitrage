use std::{collections::BTreeMap, fmt};

use arbitrage_shared::{
    Copper, Count, Database, DbKey, Faction, IMPORT_VERSION, ITEM_SCHEMA_VERSION, Import,
    ImportMarket, ImportRealm, ItemId, Market, Realm, RegionSales, SCHEMA_VERSION, Scan, ScanKind,
    Timestamp, pivot,
};

use super::lua::{Key, Table, Value};

/// What one Lua function may hold before the import starts another: Lua 5.1 stops at 2^18 - 1
/// constants a function, and every number and key written is counted, repeats included.
const CONSTANTS_PER_FILL: usize = 200_000;

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

/// Which saved database layout is being read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Layout {
    /// Version 2: each item's market values by scan time, and the latest scan's buyouts.
    Items,
    /// Version 3: each scan by time, its values held as text.
    Scans,
}

pub fn decode(value: &Value) -> Result<Database, DecodeError> {
    let root = as_table(value, "the database")?;

    let layout = match find(root, "__version") {
        None => return Err(DecodeError::UnsupportedVersion(None)),
        Some(Value::Integer(version)) if *version == i64::from(SCHEMA_VERSION) => Layout::Scans,
        Some(Value::Integer(version)) if *version == i64::from(ITEM_SCHEMA_VERSION) => {
            Layout::Items
        }
        Some(Value::Integer(version)) => {
            return Err(DecodeError::UnsupportedVersion(Some(*version)));
        }
        Some(_) => return Err(schema("the database", "__version is not an integer")),
    };

    let mut meta = None;
    let mut realms = None;
    for (key, entry) in root {
        match string_key(key) {
            Some("__version") => {}
            Some("meta") => meta = Some(entry),
            Some("realms") => realms = Some(entry),
            _ => return Err(unknown_key(key, "the database")),
        }
    }

    Ok(Database {
        last_replicate_scan: decode_root_meta(required(meta, "meta", "the database")?)?,
        realms: decode_realms(required(realms, "realms", "the database")?, layout)?,
    })
}

/// Reads `ARBITRAGE_GREY_ITEMS`, the item IDs the addon has seen to be grey. It only trims the
/// import, so anything unreadable is left out rather than failing the sync.
pub fn decode_grey_items(value: &Value) -> std::collections::BTreeSet<ItemId> {
    let Value::Table(table) = value else {
        return std::collections::BTreeSet::new();
    };
    table
        .iter()
        .filter(|(_, entry)| matches!(entry, Value::Boolean(true)))
        .filter_map(|(key, _)| match key {
            Key::Integer(id) => u64::try_from(*id).ok().and_then(ItemId::new),
            Key::String(_) => None,
        })
        .collect()
}

fn decode_root_meta(value: &Value) -> Result<Option<Timestamp>, DecodeError> {
    let meta = as_table(value, "the database meta")?;
    let mut last_replicate_scan = None;

    for (key, entry) in meta {
        match string_key(key) {
            Some("lastReplicateScan") => {
                last_replicate_scan = Some(timestamp(entry, "lastReplicateScan")?);
            }
            _ => return Err(unknown_key(key, "the database meta")),
        }
    }

    Ok(last_replicate_scan)
}

fn decode_realms(value: &Value, layout: Layout) -> Result<BTreeMap<String, Realm>, DecodeError> {
    let table = as_table(value, "realms")?;
    let mut realms = BTreeMap::new();

    for (key, entry) in table {
        let name = string_key(key).ok_or_else(|| unknown_key(key, "realms"))?;
        realms.insert(name.to_owned(), decode_realm(entry, name, layout)?);
    }

    Ok(realms)
}

fn decode_realm(value: &Value, name: &str, layout: Layout) -> Result<Realm, DecodeError> {
    let what = format!("realm {name}");
    let table = as_table(value, &what)?;
    let mut region = None;
    let mut markets = None;
    let mut vendor_prices = None;

    for (key, entry) in table {
        match string_key(key) {
            Some("region") => region = Some(entry),
            Some("markets") => markets = Some(entry),
            Some("vendorPrices") => vendor_prices = Some(entry),
            _ => return Err(unknown_key(key, &what)),
        }
    }

    Ok(Realm {
        region: exact(required(region, "region", &what)?)
            .and_then(|region| u32::try_from(region).ok())
            .filter(|&region| region > 0)
            .ok_or_else(|| schema(&what, "the region is not a positive integer"))?,
        markets: decode_markets(required(markets, "markets", &what)?, layout)?,
        vendor_prices: vendor_prices.map_or_else(|| Ok(BTreeMap::new()), decode_vendor_prices)?,
    })
}

fn decode_markets(value: &Value, layout: Layout) -> Result<BTreeMap<Faction, Market>, DecodeError> {
    let table = as_table(value, "markets")?;
    let mut markets = BTreeMap::new();

    for (key, entry) in table {
        let faction = string_key(key)
            .and_then(Faction::from_name)
            .ok_or_else(|| unknown_key(key, "markets"))?;
        let market = match layout {
            Layout::Items => decode_item_market(entry, faction)?,
            Layout::Scans => decode_scan_market(entry, faction)?,
        };
        markets.insert(faction, market);
    }

    Ok(markets)
}

fn decode_item_market(value: &Value, faction: Faction) -> Result<Market, DecodeError> {
    let what = format!("the {} market", faction.name());
    let table = as_table(value, &what)?;
    let mut meta = None;
    let mut items = None;
    let mut latest_buyouts = None;

    for (key, entry) in table {
        match string_key(key) {
            Some("meta") => meta = Some(entry),
            Some("items") => items = Some(entry),
            Some("latestBuyouts") => latest_buyouts = Some(entry),
            _ => return Err(unknown_key(key, &what)),
        }
    }

    let (last_scan, last_played) = decode_market_meta(required(meta, "meta", &what)?, &what)?;
    let items = items.map_or_else(|| Ok(BTreeMap::new()), decode_items)?;
    let latest_buyouts = latest_buyouts.map_or_else(|| Ok(BTreeMap::new()), decode_buyouts)?;
    Ok(Market {
        last_played,
        scans: pivot::scans_from_items(items, last_scan, latest_buyouts),
    })
}

fn decode_market_meta(
    value: &Value,
    what: &str,
) -> Result<(Option<Timestamp>, Option<Timestamp>), DecodeError> {
    let meta = as_table(value, what)?;
    let mut last_scan = None;
    let mut last_played = None;

    for (key, entry) in meta {
        match string_key(key) {
            Some("lastScan") => last_scan = Some(timestamp(entry, "lastScan")?),
            Some("lastPlayed") => last_played = Some(timestamp(entry, "lastPlayed")?),
            _ => return Err(unknown_key(key, what)),
        }
    }

    Ok((last_scan, last_played))
}

fn decode_items(
    value: &Value,
) -> Result<BTreeMap<DbKey, BTreeMap<Timestamp, Copper>>, DecodeError> {
    let table = as_table(value, "items")?;
    let mut items = BTreeMap::new();

    for (key, entry) in table {
        let db_key = string_key(key).ok_or_else(|| unknown_key(key, "items"))?;
        items.insert(DbKey::new(db_key), decode_item(entry, db_key)?);
    }

    Ok(items)
}

fn decode_item(value: &Value, db_key: &str) -> Result<BTreeMap<Timestamp, Copper>, DecodeError> {
    let what = format!("item {db_key}");
    let table = as_table(value, &what)?;
    let mut scans = None;

    for (key, entry) in table {
        match string_key(key) {
            Some("scans") => scans = Some(entry),
            _ => return Err(unknown_key(key, &what)),
        }
    }

    let table = as_table(required(scans, "scans", &what)?, &what)?;
    let mut history = BTreeMap::new();
    for (key, entry) in table {
        history.insert(scan_time(key, &what)?, copper(entry, &what)?);
    }

    Ok(history)
}

fn decode_buyouts(value: &Value) -> Result<BTreeMap<DbKey, Copper>, DecodeError> {
    let table = as_table(value, "latestBuyouts")?;
    let mut buyouts = BTreeMap::new();

    for (key, entry) in table {
        let db_key = string_key(key).ok_or_else(|| unknown_key(key, "latestBuyouts"))?;
        buyouts.insert(DbKey::new(db_key), copper(entry, "latestBuyouts")?);
    }

    Ok(buyouts)
}

fn decode_scan_market(value: &Value, faction: Faction) -> Result<Market, DecodeError> {
    let what = format!("the {} market", faction.name());
    let table = as_table(value, &what)?;
    let mut meta = None;
    let mut scans = None;

    for (key, entry) in table {
        match string_key(key) {
            Some("meta") => meta = Some(entry),
            Some("scans") => scans = Some(entry),
            _ => return Err(unknown_key(key, &what)),
        }
    }

    let mut last_played = None;
    for (key, entry) in as_table(required(meta, "meta", &what)?, &what)? {
        match string_key(key) {
            Some("lastPlayed") => last_played = Some(timestamp(entry, "lastPlayed")?),
            _ => return Err(unknown_key(key, &what)),
        }
    }

    let mut decoded = Vec::new();
    if let Some(scans) = scans {
        for (key, entry) in as_table(scans, &what)? {
            decoded.push(decode_scan(scan_time(key, &what)?, entry)?);
        }
    }
    // The table is ordered by key, and its keys are the scan times.
    Ok(Market {
        last_played,
        scans: decoded,
    })
}

/// Reads one saved scan: its kind, and its values in one or more pieces of text.
fn decode_scan(at: Timestamp, value: &Value) -> Result<Scan, DecodeError> {
    let what = format!("scan {}", at.get());
    let table = as_table(value, &what)?;
    let mut scan = Scan {
        at,
        ..Scan::default()
    };
    let mut pieces = Vec::new();

    for (key, entry) in table {
        match key {
            Key::String(name) if name == b"kind" => {
                scan.kind = match entry {
                    Value::String(kind) => str::from_utf8(kind).ok().and_then(ScanKind::from_name),
                    _ => None,
                }
                .ok_or_else(|| schema(&what, "the kind is not full or quick"))?;
            }
            Key::Integer(_) => match entry {
                Value::String(piece) => pieces.push(piece),
                _ => return Err(schema(&what, "a piece of the scan is not text")),
            },
            Key::String(_) => return Err(unknown_key(key, &what)),
        }
    }

    for piece in pieces {
        add_scan_piece(&mut scan, piece, &what)?;
    }
    Ok(scan)
}

/// Reads one piece of a saved scan: its keys on the first line, separated by commas, then a line
/// per value, `name=` followed by the value for each key, 0 for none. A value this version doesn't
/// know is left out, as the addon leaves it out.
fn add_scan_piece(scan: &mut Scan, piece: &[u8], what: &str) -> Result<(), DecodeError> {
    let text =
        str::from_utf8(piece).map_err(|_| schema(what, "a piece of the scan is not text"))?;
    let mut lines = text.split('\n');
    let keys: Vec<DbKey> = lines
        .next()
        .unwrap_or_default()
        .split(',')
        .filter(|key| !key.is_empty())
        .map(DbKey::new)
        .collect();

    for line in lines {
        let (name, list) = line
            .split_once('=')
            .ok_or_else(|| schema(what, "a line of the scan names no value"))?;
        let values = list
            .split(',')
            .filter(|value| !value.is_empty())
            .map(|value| {
                value
                    .parse::<u64>()
                    .ok()
                    .filter(|number| number.to_string() == value)
                    .ok_or_else(|| {
                        schema(what, &format!("{name} holds something other than a count"))
                    })
            })
            .collect::<Result<Vec<_>, _>>()?;
        if values.len() != keys.len() {
            return Err(schema(what, &format!("{name} has a value for each key")));
        }
        let pairs = keys
            .iter()
            .cloned()
            .zip(values)
            .filter(|&(_, value)| value > 0);
        match name {
            "marketValues" => scan.market_values.extend(copper_pairs(pairs, what)?),
            "buyouts" => scan
                .buyouts
                .get_or_insert_default()
                .extend(copper_pairs(pairs, what)?),
            "quantities" => scan
                .quantities
                .get_or_insert_default()
                .extend(count_pairs(pairs, what)?),
            "auctions" => scan
                .auctions
                .get_or_insert_default()
                .extend(count_pairs(pairs, what)?),
            _ => {}
        }
    }
    Ok(())
}

fn copper_pairs(
    pairs: impl Iterator<Item = (DbKey, u64)>,
    what: &str,
) -> Result<Vec<(DbKey, Copper)>, DecodeError> {
    pairs
        .map(|(key, value)| {
            Copper::new(value)
                .map(|value| (key, value))
                .ok_or_else(|| schema(what, "a price is past the exact integer limit"))
        })
        .collect()
}

fn count_pairs(
    pairs: impl Iterator<Item = (DbKey, u64)>,
    what: &str,
) -> Result<Vec<(DbKey, Count)>, DecodeError> {
    pairs
        .map(|(key, value)| {
            Count::new(value)
                .map(|value| (key, value))
                .ok_or_else(|| schema(what, "a count is past the exact integer limit"))
        })
        .collect()
}

fn decode_vendor_prices(
    value: &Value,
) -> Result<BTreeMap<String, BTreeMap<ItemId, Copper>>, DecodeError> {
    let table = as_table(value, "vendorPrices")?;
    let mut factions = BTreeMap::new();

    for (key, entry) in table {
        let faction = string_key(key).ok_or_else(|| unknown_key(key, "vendorPrices"))?;
        let what = format!("vendor prices for {faction}");
        let prices = as_table(entry, &what)?;
        let mut by_item = BTreeMap::new();

        for (item_key, price) in prices {
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

fn scan_time(key: &Key, what: &str) -> Result<Timestamp, DecodeError> {
    let Key::Integer(seconds) = key else {
        return Err(schema(what, "a scan key is not an integer"));
    };
    u64::try_from(*seconds)
        .ok()
        .and_then(Timestamp::new)
        .ok_or_else(|| schema(what, "a scan key is out of range"))
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
        .iter()
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

/// Writes the import as the Lua file the addon loads: `ARBITRAGE_IMPORT`, then functions that fill
/// its large tables.
///
/// Per market it holds its scan times, and per item a list of numbers: when the item was last
/// seen, then for each day its number followed by that day's market value, buyout, quantity, and
/// auctions, each `total * 1024 + count`. Lua 5.1 caps a function at 2^18 - 1 constants, more than
/// a busy market's items hold, so the large tables are written empty and filled afterwards by as
/// many functions as they need.
pub fn encode_import(import: &Import) -> Vec<u8> {
    let mut writer = Writer::default();
    writer.out.extend_from_slice(b"ARBITRAGE_IMPORT = ");
    writer.begin();

    writer.string_key("__version");
    writer.unsigned(u64::from(IMPORT_VERSION));
    writer.end_entry();

    writer.string_key("meta");
    writer.begin();
    writer.end();
    writer.end_entry();

    writer.string_key("realms");
    writer.begin();
    for (name, realm) in &import.realms {
        writer.string_key(name);
        let path = format!("ARBITRAGE_IMPORT[{}]", quoted("realms"));
        write_realm(&mut writer, &format!("{path}[{}]", quoted(name)), realm);
        writer.end_entry();
    }
    writer.end();
    writer.end_entry();

    writer.string_key("regions");
    writer.begin();
    for (&region, sales) in &import.regions {
        writer.integer_key(u64::from(region));
        write_sales(
            &mut writer,
            &format!("ARBITRAGE_IMPORT[{}][{region}]", quoted("regions")),
            sales,
        );
        writer.end_entry();
    }
    writer.end();
    writer.end_entry();

    writer.end();
    writer.out.extend_from_slice(b";\n");
    writer.out.append(&mut writer.fills);
    writer.out
}

fn write_realm(writer: &mut Writer, path: &str, realm: &ImportRealm) {
    writer.begin();

    writer.string_key("region");
    writer.unsigned(u64::from(realm.region));
    writer.end_entry();

    writer.string_key("markets");
    writer.begin();
    for (faction, market) in &realm.markets {
        writer.string_key(faction.name());
        let path = format!("{path}[{}][{}]", quoted("markets"), quoted(faction.name()));
        write_market(writer, &path, market);
        writer.end_entry();
    }
    writer.end();
    writer.end_entry();

    writer.string_key("vendorPrices");
    writer.begin();
    for (faction, prices) in &realm.vendor_prices {
        writer.string_key(faction);
        let path = format!("{path}[{}][{}]", quoted("vendorPrices"), quoted(faction));
        writer.fill(
            &path,
            prices
                .iter()
                .map(|(item, price)| (quoted(&item.get().to_string()), price.get().to_string(), 2)),
        );
        writer.end_entry();
    }
    writer.end();
    writer.end_entry();

    writer.end();
}

fn write_market(writer: &mut Writer, path: &str, market: &ImportMarket) {
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

    for (name, times) in [
        ("scans", &market.scans),
        ("quickScans", &market.quick_scans),
    ] {
        writer.string_key(name);
        writer.begin();
        for at in times {
            writer.unsigned(at.get());
            writer.end_entry();
        }
        writer.end();
        writer.end_entry();
    }

    writer.string_key("items");
    writer.fill(
        &format!("{path}[{}]", quoted("items")),
        market.items.iter().map(|(db_key, item)| {
            let mut numbers = vec![item.latest.get()];
            for (&day, totals) in &item.days {
                numbers.push(day);
                numbers.extend(totals.values());
            }
            (
                quoted(db_key.as_str()),
                lua_list(&numbers),
                numbers.len() + 1,
            )
        }),
    );
    writer.end_entry();

    // Present even when empty, so the addon knows the lists are synced.
    writer.string_key("buyouts");
    writer.begin();
    for (kind, list) in [
        ("items", &market.item_buyouts),
        ("variants", &market.variant_buyouts),
    ] {
        if let Some(list) = list {
            writer.string_key(kind);
            writer.begin();
            writer.string_key("at");
            writer.unsigned(list.at.get());
            writer.end_entry();
            writer.string_key("prices");
            writer.fill(
                &format!(
                    "{path}[{}][{}][{}]",
                    quoted("buyouts"),
                    quoted(kind),
                    quoted("prices")
                ),
                list.prices
                    .iter()
                    .map(|(db_key, price)| (quoted(db_key.as_str()), price.get().to_string(), 2)),
            );
            writer.end_entry();
            writer.end();
            writer.end_entry();
        }
    }
    writer.end();
    writer.end_entry();

    writer.end();
}

/// A region's sales: per item ID its average sale price, sale rate, and units sold a day.
fn write_sales(writer: &mut Writer, path: &str, sales: &RegionSales) {
    writer.begin();
    writer.string_key("at");
    writer.unsigned(sales.at.get());
    writer.end_entry();
    writer.string_key("items");
    writer.fill(
        &format!("{path}[{}]", quoted("items")),
        sales.items.iter().map(|(item, sale)| {
            let value = format!(
                "{{{},{},{}}}",
                sale.average_price().get(),
                decimal_thousandths(sale.sale_rate_thousandths().get()),
                decimal_thousandths(sale.sold_per_day_thousandths().get()),
            );
            (item.get().to_string(), value, 4)
        }),
    );
    writer.end_entry();
    writer.end();
}

/// Writes thousandths as the decimal TSM published, such as 887 as `0.887`.
fn decimal_thousandths(value: u64) -> String {
    let whole = value / 1_000;
    let fraction = value % 1_000;
    if fraction == 0 {
        return whole.to_string();
    }
    format!("{whole}.{fraction:03}")
        .trim_end_matches('0')
        .to_owned()
}

fn lua_list(numbers: &[u64]) -> String {
    let mut text = String::from("{");
    for (index, number) in numbers.iter().enumerate() {
        if index > 0 {
            text.push(',');
        }
        text.push_str(&number.to_string());
    }
    text.push('}');
    text
}

fn quoted(text: &str) -> String {
    let mut out = Vec::new();
    write_quoted(&mut out, text.as_bytes());
    String::from_utf8(out).unwrap_or_else(|error| unreachable!("{error}"))
}

#[derive(Default)]
struct Writer {
    out: Vec<u8>,
    /// Statements that fill the large tables, written after `ARBITRAGE_IMPORT`.
    fills: Vec<u8>,
}

impl Writer {
    fn begin(&mut self) {
        self.out.extend_from_slice(b"{\n");
    }

    fn end(&mut self) {
        self.out.push(b'}');
    }

    fn end_entry(&mut self) {
        self.out.extend_from_slice(b",\n");
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

    /// Writes an empty table, and functions that fill the table at `path` with `entries`, each a
    /// key, its value, and how many constants they hold. A function ends before it would pass
    /// [`CONSTANTS_PER_FILL`].
    fn fill(&mut self, path: &str, entries: impl Iterator<Item = (String, String, usize)>) {
        self.begin();
        self.end();

        let mut constants = 0;
        let mut open = false;
        for (key, value, count) in entries {
            if open && constants + count > CONSTANTS_PER_FILL {
                self.close_fill(path);
                open = false;
            }
            if !open {
                self.fills.extend_from_slice(b"(function(t)\n");
                open = true;
                constants = 0;
            }
            constants += count;
            self.fills.extend_from_slice(b"t[");
            self.fills.extend_from_slice(key.as_bytes());
            self.fills.extend_from_slice(b"] = ");
            self.fills.extend_from_slice(value.as_bytes());
            self.fills.push(b'\n');
        }
        if open {
            self.close_fill(path);
        }
    }

    fn close_fill(&mut self, path: &str) {
        // The semicolon keeps Lua from reading the next line's parenthesis as another call.
        self.fills.extend_from_slice(b"end)(");
        self.fills.extend_from_slice(path.as_bytes());
        self.fills.extend_from_slice(b");\n");
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
        CONSTANTS_PER_FILL, Copper, Database, DbKey, DecodeError, Faction, Import, ImportMarket,
        ImportRealm, ItemId, Timestamp, Writer, decimal_thousandths, decode, decode_grey_items,
        encode_import,
    };
    use crate::saved_variables::lua::parse_value;
    use arbitrage_shared::{
        BuyoutList, Count, DayTotals, ImportItem, RegionSales, Sale, Scan, ScanKind,
    };
    use std::collections::{BTreeMap, BTreeSet};

    fn decode_source(source: &[u8]) -> Result<Database, DecodeError> {
        decode(&parse_value(source).expect("the fixture source should parse"))
    }

    fn at(seconds: u64) -> Timestamp {
        Timestamp::new(seconds).unwrap()
    }

    fn prices(entries: &[(&str, u64)]) -> BTreeMap<DbKey, Copper> {
        entries
            .iter()
            .map(|&(key, value)| (DbKey::new(key), Copper::new(value).unwrap()))
            .collect()
    }

    fn counts(entries: &[(&str, u64)]) -> BTreeMap<DbKey, Count> {
        entries
            .iter()
            .map(|&(key, value)| (DbKey::new(key), Count::new(value).unwrap()))
            .collect()
    }

    /// A version 3 database with one Alliance market holding `scans`, written as Lua entries.
    fn scans_database(scans: &str) -> String {
        format!(
            "{{\n[\"__version\"] = 3,\n[\"meta\"] = {{\n}},\n[\"realms\"] = {{\n[\"Test Realm\"] = {{\n[\"region\"] = 1,\n[\"markets\"] = {{\n[\"Alliance\"] = {{\n[\"meta\"] = {{\n[\"lastPlayed\"] = 1700000050,\n}},\n[\"scans\"] = {{\n{scans}}},\n}},\n}},\n}},\n}},\n}}"
        )
    }

    fn alliance_scans(database: &Database) -> &[Scan] {
        &database.realms["Test Realm"].markets[&Faction::Alliance].scans
    }

    #[test]
    fn reads_version_3_scans_from_their_text() {
        let source = scans_database(concat!(
            "[1700000100] = {\n[\"kind\"] = \"full\",\n",
            "\"2589,equip:9868:-18\\nmarketValues=1234,0\\n",
            "buyouts=1200,5000\\nquantities=40,1\\nauctions=4,1\",\n",
            "\"4306\\nmarketValues=70\\nbuyouts=65\\nquantities=9\\nauctions=2\\nbids=1\",\n",
            "},\n",
            "[1700003700] = {\n[\"kind\"] = \"quick\",\n",
            "\"2589\\nbuyouts=1100\\nquantities=38\",\n},\n",
            "[1700007300] = {\n[\"kind\"] = \"full\",\n},\n",
        ));

        let database = decode_source(source.as_bytes()).expect("the scans should decode");

        assert_eq!(
            database.realms["Test Realm"].markets[&Faction::Alliance].last_played,
            Timestamp::new(1_700_000_050)
        );
        assert_eq!(
            alliance_scans(&database),
            [
                Scan {
                    at: at(1_700_000_100),
                    kind: ScanKind::Full,
                    market_values: prices(&[("2589", 1_234), ("4306", 70)]),
                    buyouts: Some(prices(&[
                        ("2589", 1_200),
                        ("4306", 65),
                        ("equip:9868:-18", 5_000)
                    ])),
                    quantities: Some(counts(&[("2589", 40), ("4306", 9), ("equip:9868:-18", 1)])),
                    auctions: Some(counts(&[("2589", 4), ("4306", 2), ("equip:9868:-18", 1)])),
                },
                Scan {
                    at: at(1_700_003_700),
                    kind: ScanKind::Quick,
                    buyouts: Some(prices(&[("2589", 1_100)])),
                    quantities: Some(counts(&[("2589", 38)])),
                    ..Scan::default()
                },
                Scan {
                    at: at(1_700_007_300),
                    ..Scan::default()
                },
            ]
        );
    }

    #[test]
    fn rejects_a_malformed_version_3_scan() {
        for (label, scan) in [
            (
                "a value for each key",
                "[1] = {\n[\"kind\"] = \"full\",\n\"2589\\nmarketValues=1,2\",\n},\n",
            ),
            (
                "an unknown kind",
                "[1] = {\n[\"kind\"] = \"slow\",\n\"2589\\nbuyouts=5\",\n},\n",
            ),
            (
                "a line that names no value",
                "[1] = {\n[\"kind\"] = \"full\",\n\"2589\\n1234\",\n},\n",
            ),
            (
                "a fractional price",
                "[1] = {\n[\"kind\"] = \"full\",\n\"2589\\nbuyouts=1.5\",\n},\n",
            ),
            (
                "a piece that isn't text",
                "[1] = {\n[\"kind\"] = \"full\",\n{},\n},\n",
            ),
            (
                "a string scan time",
                "[\"1\"] = {\n[\"kind\"] = \"full\",\n},\n",
            ),
        ] {
            assert!(
                matches!(
                    decode_source(scans_database(scan).as_bytes()),
                    Err(DecodeError::Schema(_))
                ),
                "{label} should be rejected"
            );
        }
    }

    #[test]
    fn reads_grey_items_and_skips_anything_else() {
        let value =
            parse_value(b"{\n[3300] = true,\n[3301] = false,\n[\"x\"] = true,\n[-1] = true,\n}")
                .unwrap();

        assert_eq!(
            decode_grey_items(&value),
            BTreeSet::from([ItemId::new(3_300).unwrap()])
        );
        assert!(decode_grey_items(&parse_value(b"\"not a table\"").unwrap()).is_empty());
    }

    #[test]
    fn writes_the_import_with_its_large_tables_filled_after_it() {
        let item = ImportItem {
            latest: at(1_700_000_100),
            days: BTreeMap::from([(
                19_675,
                DayTotals {
                    market_value: 2_500 * 1024 + 2,
                    buyout: 1_100 * 1024 + 1,
                    quantity: 40 * 1024 + 1,
                    auctions: 0,
                },
            )]),
        };
        let market = ImportMarket {
            last_scan: Timestamp::new(1_700_000_100),
            item_buyouts: Some(BuyoutList {
                at: at(1_700_000_100),
                prices: prices(&[("2589", 1_100)]),
            }),
            variant_buyouts: Some(BuyoutList {
                at: at(1_699_990_000),
                prices: prices(&[("equip:9868:-18", 5_000)]),
            }),
            scans: BTreeSet::from([at(1_699_990_000), at(1_700_000_100)]),
            quick_scans: BTreeSet::from([at(1_700_000_200)]),
            items: BTreeMap::from([(DbKey::new("2589"), item)]),
        };
        let import = Import {
            realms: BTreeMap::from([(
                "Test Realm".to_owned(),
                ImportRealm {
                    region: 1,
                    markets: BTreeMap::from([(Faction::Alliance, market)]),
                    vendor_prices: BTreeMap::from([(
                        "Alliance".to_owned(),
                        BTreeMap::from([(ItemId::new(2589).unwrap(), Copper::new(5).unwrap())]),
                    )]),
                },
            )]),
            regions: BTreeMap::from([(
                1,
                RegionSales {
                    region: 1,
                    at: at(1_794_473_469),
                    items: BTreeMap::from([(
                        ItemId::new(785).unwrap(),
                        Sale(
                            Copper::new(40).unwrap(),
                            Count::new(887).unwrap(),
                            Count::new(1_554_020).unwrap(),
                        ),
                    )]),
                },
            )]),
        };

        assert_eq!(
            String::from_utf8(encode_import(&import)).unwrap(),
            concat!(
                "ARBITRAGE_IMPORT = {\n[\"__version\"] = 4,\n[\"meta\"] = {\n},\n",
                "[\"realms\"] = {\n",
                "[\"Test Realm\"] = {\n[\"region\"] = 1,\n[\"markets\"] = {\n",
                "[\"Alliance\"] = {\n[\"meta\"] = {\n[\"lastScan\"] = 1700000100,\n},\n",
                "[\"scans\"] = {\n1699990000,\n1700000100,\n},\n",
                "[\"quickScans\"] = {\n1700000200,\n},\n",
                "[\"items\"] = {\n},\n",
                "[\"buyouts\"] = {\n",
                "[\"items\"] = {\n[\"at\"] = 1700000100,\n[\"prices\"] = {\n},\n},\n",
                "[\"variants\"] = {\n[\"at\"] = 1699990000,\n[\"prices\"] = {\n},\n},\n},\n},\n},\n",
                "[\"vendorPrices\"] = {\n[\"Alliance\"] = {\n},\n},\n},\n},\n",
                "[\"regions\"] = {\n[1] = {\n[\"at\"] = 1794473469,\n[\"items\"] = {\n},\n},\n},\n};\n",
                "(function(t)\nt[\"2589\"] = {1700000100,19675,2560002,1126401,40961,0}\n",
                "end)(ARBITRAGE_IMPORT[\"realms\"][\"Test Realm\"][\"markets\"][\"Alliance\"][\"items\"]);\n",
                "(function(t)\nt[\"2589\"] = 1100\n",
                "end)(ARBITRAGE_IMPORT[\"realms\"][\"Test Realm\"][\"markets\"][\"Alliance\"][\"buyouts\"][\"items\"][\"prices\"]);\n",
                "(function(t)\nt[\"equip:9868:-18\"] = 5000\n",
                "end)(ARBITRAGE_IMPORT[\"realms\"][\"Test Realm\"][\"markets\"][\"Alliance\"][\"buyouts\"][\"variants\"][\"prices\"]);\n",
                "(function(t)\nt[\"2589\"] = 5\n",
                "end)(ARBITRAGE_IMPORT[\"realms\"][\"Test Realm\"][\"vendorPrices\"][\"Alliance\"]);\n",
                "(function(t)\nt[785] = {40,0.887,1554.02}\n",
                "end)(ARBITRAGE_IMPORT[\"regions\"][1][\"items\"]);\n",
            )
        );
    }

    #[test]
    fn a_fill_starts_another_function_before_passing_the_constant_cap() {
        let mut writer = Writer::default();
        let half = CONSTANTS_PER_FILL / 2;
        writer.fill(
            "T",
            [("1", half), ("2", half), ("3", 1)]
                .into_iter()
                .map(|(key, count)| (key.to_owned(), "true".to_owned(), count)),
        );

        assert_eq!(
            String::from_utf8(writer.fills).unwrap(),
            "(function(t)\nt[1] = true\nt[2] = true\nend)(T);\n(function(t)\nt[3] = true\nend)(T);\n"
        );
        assert_eq!(writer.out, b"{\n}");
    }

    #[test]
    fn rates_are_written_as_the_decimals_tsm_published() {
        assert_eq!(decimal_thousandths(887), "0.887");
        assert_eq!(decimal_thousandths(20), "0.02");
        assert_eq!(decimal_thousandths(1_554_024), "1554.024");
        assert_eq!(decimal_thousandths(3_000), "3");
        assert_eq!(decimal_thousandths(0), "0");
    }

    #[test]
    fn rejects_another_version() {
        for version in [1, 4] {
            let source = format!(
                "{{\n[\"__version\"] = {version},\n[\"meta\"] = {{\n}},\n[\"realms\"] = {{\n}},\n}}"
            );

            assert_eq!(
                decode_source(source.as_bytes()),
                Err(DecodeError::UnsupportedVersion(Some(version)))
            );
        }
    }

    #[test]
    fn rejects_a_realm_without_a_positive_region() {
        for region in ["", "[\"region\"] = 0,\n"] {
            let source = format!(
                "{{\n[\"__version\"] = 2,\n[\"meta\"] = {{\n}},\n[\"realms\"] = {{\n[\"Test Realm\"] = {{\n{region}[\"markets\"] = {{\n}},\n}},\n}},\n}}"
            );

            assert!(
                matches!(
                    decode_source(source.as_bytes()),
                    Err(DecodeError::Schema(_))
                ),
                "{region:?} should be rejected"
            );
        }
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
            b"{\n[\"__version\"] = 2,\n[\"meta\"] = {\n},\n[\"realms\"] = {\n},\n[\"extra\"] = 1,\n}";

        assert!(matches!(decode_source(source), Err(DecodeError::Schema(_))));
    }

    #[test]
    fn rejects_a_float_price() {
        let source = b"{\n[\"__version\"] = 2,\n[\"meta\"] = {\n},\n[\"realms\"] = {\n[\"Test Realm\"] = {\n[\"region\"] = 1,\n[\"markets\"] = {\n[\"Alliance\"] = {\n[\"meta\"] = {\n},\n[\"latestBuyouts\"] = {\n[\"2589\"] = 12.5,\n},\n},\n},\n},\n},\n}";

        assert!(matches!(decode_source(source), Err(DecodeError::Schema(_))));
    }

    #[test]
    fn rejects_a_string_scan_key() {
        let source = b"{\n[\"__version\"] = 2,\n[\"meta\"] = {\n},\n[\"realms\"] = {\n[\"Test Realm\"] = {\n[\"region\"] = 1,\n[\"markets\"] = {\n[\"Alliance\"] = {\n[\"meta\"] = {\n},\n[\"items\"] = {\n[\"2589\"] = {\n[\"scans\"] = {\n[\"1700000100\"] = 12,\n},\n},\n},\n},\n},\n},\n},\n}";

        assert!(matches!(decode_source(source), Err(DecodeError::Schema(_))));
    }

    #[test]
    fn rejects_a_price_past_the_exact_integer_limit() {
        let source = b"{\n[\"__version\"] = 2,\n[\"meta\"] = {\n},\n[\"realms\"] = {\n[\"Test Realm\"] = {\n[\"region\"] = 1,\n[\"markets\"] = {\n[\"Alliance\"] = {\n[\"meta\"] = {\n},\n[\"latestBuyouts\"] = {\n[\"2589\"] = 9007199254740993,\n},\n},\n},\n},\n},\n}";

        assert!(matches!(decode_source(source), Err(DecodeError::Schema(_))));
    }
}

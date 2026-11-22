local NewEnvironment = dofile("tests/support/Environment.lua")

describe("DatabaseFilters", function()
  local DAY = 24 * 60 * 60
  local NOW = 100 * DAY
  local environment
  local harness
  local content
  local components

  local function Plain(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x(.-)|r", "%1"))
  end

  local function AddItem(dbKey, item)
    local itemID = tonumber(dbKey) or tonumber(dbKey:match("^equip:(%d+)"))
    harness.itemClasses[itemID] = item.class[1]
    harness.itemSubClasses[itemID] = item.class[2]
    harness.itemEquipLocs[itemID] = item.equipLoc
    if item.name then
      local _, link = harness.ns.Keys.ToLink(dbKey)
      harness.itemInfo[link] = { item.name, link, item.quality, item.itemLevel, item.requiredLevel }
      harness.itemInfo[itemID] = harness.itemInfo[link]
      harness.itemStats[link] = item.stats
    end
    harness.databaseItems[dbKey] = { days = {}, latest = NOW - item.age }
    harness.marketValues[dbKey] = { value = item.market, scanCount = 5, isUncertain = item.uncertain, reasons = {} }
    harness.latestBuyouts[dbKey] = item.latestBuyout
    harness.craftingCosts[itemID] = item.craft
  end

  local function VisibleKeys()
    local keys = {}
    for _, row in ipairs(components.scrollBox.frames) do
      if row:IsShown() then
        keys[#keys + 1] = row.item.dbKey
      end
    end
    return keys
  end

  -- The line above the table without color codes; empty while unfiltered.
  local function FilterLine()
    for _, fontString in ipairs(harness.createdFontStrings) do
      if fontString.parent == content and fontString.template == "GameFontHighlightSmall" then
        return Plain(fontString.text)
      end
    end
  end

  local function TableTop()
    return components.tableBackground.points[1][5]
  end

  local function Entry(menu, label)
    for _, entry in ipairs(menu.entries) do
      if (entry.label and Plain(entry.label) == label) or entry.title == label then
        return entry, menu.entries
      end
    end
    error("no menu entry " .. label)
  end

  local function Labels(menu)
    local labels = {}
    for _, entry in ipairs(menu.entries) do
      labels[#labels + 1] = Plain(entry.label)
    end
    return labels
  end

  local function Pick(...)
    local menu = components.filterDropdown:OpenMenu()
    for _, label in ipairs({ ... }) do
      menu = Entry(menu, label)
    end
    menu:Pick()
  end

  -- Stands in for LevelRangeFrameTemplate: editing either input reports both bounds.
  local function NewRangeFrame()
    local frame = { MinLevel = { value = 0 }, MaxLevel = { value = 0 } }
    for _, input in ipairs({ frame.MinLevel, frame.MaxLevel }) do
      function input:SetMaxLetters(letters)
        self.letters = letters
      end
      function input:SetWidth(width)
        self.width = width
      end
    end
    local function Changed()
      if frame.callback then
        frame.callback(frame.MinLevel.value, frame.MaxLevel.value)
      end
    end
    function frame:SetLevelRangeChangedCallback(callback)
      self.callback = callback
    end
    function frame:SetWidth(width)
      self.width = width
    end
    function frame:Reset()
      self.MinLevel.value = 0
      Changed()
      self.MaxLevel.value = 0
      Changed()
    end
    function frame:SetMinLevel(level)
      self.MinLevel.value = level
      Changed()
    end
    function frame:SetMaxLevel(level)
      self.MaxLevel.value = level
      Changed()
    end
    function frame:Type(min, max)
      self.MinLevel.value, self.MaxLevel.value = min, max
      Changed()
    end
    return frame
  end

  local function ShowRange(title, frame)
    local menu = components.filterDropdown:OpenMenu()
    local _, entries = Entry(menu, title)
    for index, entry in ipairs(entries) do
      if entry.title == title then
        local template = entries[index + 1]
        assert.are.equal("LevelRangeFrameTemplate", template.template)
        for _, initializer in ipairs(template.initializers) do
          initializer(frame)
        end
        return frame
      end
    end
  end

  -- Starts a game session with saved variables from an earlier one, if any, and opens the tab.
  local function StartSession(savedConfig)
    environment = NewEnvironment()
    setfenv(1, environment)
    ARBITRAGE_CONFIG = savedConfig
    local NewHarness = assert(loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
    harness = NewHarness()
    harness.SetCurrentTime(NOW)
    harness.databaseStatus.latestScan = NOW - 3600

    AddItem("500", {
      name = "Lionheart Helm",
      class = { 4, 4 },
      equipLoc = "INVTYPE_HEAD",
      quality = 4,
      itemLevel = 63,
      requiredLevel = 58,
      market = 2500000,
      age = 3600,
      latestBuyout = 2400000,
      craft = { cost = 1800000, isUncertain = false, reasons = {}, leaves = {} },
      stats = { ITEM_MOD_STRENGTH_SHORT = 18, ITEM_MOD_STAMINA_SHORT = 12, RESISTANCE0_NAME = 600 },
    })
    AddItem("600", {
      name = "Robe of the Archmage",
      class = { 4, 1 },
      equipLoc = "INVTYPE_ROBE",
      quality = 4,
      itemLevel = 62,
      requiredLevel = 57,
      market = 1200000,
      age = 5 * DAY,
      -- Below its Market Value, but not once the Auction House takes its cut.
      craft = { cost = 1150000, isUncertain = false, reasons = {}, leaves = {} },
      stats = { ITEM_MOD_INTELLECT_SHORT = 20, ITEM_MOD_SPIRIT_SHORT = 15, RESISTANCE0_NAME = 80 },
    })
    AddItem("700", {
      name = "Truesilver Breastplate",
      class = { 4, 4 },
      equipLoc = "INVTYPE_CHEST",
      quality = 3,
      itemLevel = 40,
      requiredLevel = 35,
      market = 300000,
      uncertain = true,
      age = 2 * DAY,
      latestBuyout = 290000,
      stats = {
        ITEM_MOD_STRENGTH_SHORT = 10,
        ITEM_MOD_STAMINA_SHORT = 15,
        RESISTANCE2_NAME = 10,
        RESISTANCE0_NAME = 500,
      },
    })
    -- Not loaded yet: its slot is known, its rarity and levels are not.
    AddItem("950", { class = { 4, 4 }, equipLoc = "INVTYPE_HEAD", market = 100000, age = 3600 })
    AddItem("equip:800:12722", {
      name = "Sword of the Bear",
      class = { 2, 7 },
      equipLoc = "INVTYPE_WEAPON",
      quality = 2,
      itemLevel = 30,
      requiredLevel = 25,
      market = 50000,
      age = 20 * DAY,
      stats = {
        ITEM_MOD_STRENGTH_SHORT = 5,
        ITEM_MOD_STAMINA_SHORT = 5,
        ITEM_MOD_ATTACK_POWER_SHORT = 10,
        ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 12.5,
      },
    })
    AddItem("1000", {
      name = "Idol of Ferocity",
      class = { 4, 8 },
      equipLoc = "INVTYPE_RELIC",
      quality = 3,
      itemLevel = 55,
      requiredLevel = 50,
      market = 20000,
      age = 4 * DAY,
      -- A stat without a known group or display name.
      stats = { ITEM_MOD_MYSTERY_SHORT = 3 },
    })
    AddItem("900", {
      name = "Iron Bar",
      class = { 7, 0 },
      quality = 1,
      itemLevel = 25,
      requiredLevel = 0,
      market = 1200,
      age = 3600,
      latestBuyout = 1100,
      craft = { isUnknown = true },
    })

    harness.ns.Window.Toggle()
    environment.ArbitrageWindow.Tabs[2]:Click()
    harness.RunAllTimers()
    content = harness.GetWindowContents()[2]
    components = harness.FindComponents(content)
  end

  local function Copy(value)
    if type(value) ~= "table" then
      return value
    end
    local copy = {}
    for key, inner in pairs(value) do
      copy[key] = Copy(inner)
    end
    return copy
  end

  -- Like a reload, the saved variables are written out and read back, sharing no tables.
  local function Reload()
    StartSession(Copy(environment.ARBITRAGE_CONFIG))
  end

  before_each(function()
    StartSession()
  end)

  it("offers only the categories, slots, and rarities in the database, in short grouped lists", function()
    setfenv(1, environment)
    assert.are.same({ "500", "600", "700", "950", "equip:800:12722", "1000", "900" }, VisibleKeys())
    local menu = components.filterDropdown:OpenMenu()

    local category = Entry(menu, "Category")
    assert.are.same({ "All categories", "Armor", "Tradeskill", "Weapon" }, Labels(category))
    local armor = Entry(category, "Armor")
    assert.are.same({ "All Armor", "Relics", "Cloth", "Plate" }, Labels(armor))
    assert.are.same({ "All Relics", "Idols" }, Labels(Entry(armor, "Relics")))
    local weapon = Entry(category, "Weapon")
    assert.are.same({ "All Weapon", "One-Handed" }, Labels(weapon))
    assert.are.same({ "All One-Handed", "One-Handed Swords" }, Labels(Entry(weapon, "One-Handed")))

    local slot = Entry(menu, "Slot")
    assert.are.same({ "Armor", "Weapons" }, Labels(slot))
    assert.are.same({ "Head", "Chest" }, Labels(Entry(slot, "Armor")))
    assert.are.same({ "One-Hand", "Relic" }, Labels(Entry(slot, "Weapons")))

    assert.are.same({ "Common", "Uncommon", "Rare", "Epic" }, Labels(Entry(menu, "Rarity")))
    assert.are.equal("|cffa335eeEpic|r", Entry(menu, "Rarity").entries[4].label)
  end)

  it("lists the active filters above the table, moving it down a row", function()
    setfenv(1, environment)
    assert.are.equal("", FilterLine())
    assert.are.equal(-4, TableTop())

    Pick("Category", "Armor", "Plate")
    assert.are.equal("Filters: Armor > Plate", FilterLine())
    assert.are.equal(3, #VisibleKeys())
    assert.are.equal(-24, TableTop())

    -- A search narrows the rows, but the line stays about the filters.
    components.searchBox:Type("helm")
    assert.are.equal("Filters: Armor > Plate", FilterLine())
    assert.are.equal(1, #VisibleKeys())
    components.searchBox:SetText("")

    components.filterDropdown.ResetButton:Click()
    assert.are.equal("", FilterLine())
    assert.are.equal(-4, TableTop())

    -- Searching alone shows in the search box, so it leaves the table where it is.
    components.searchBox:Type("helm")
    assert.are.equal("", FilterLine())
    assert.are.equal(-4, TableTop())
  end)

  it("narrows to a category, a group of its subcategories, or one subcategory", function()
    setfenv(1, environment)
    Pick("Category", "Armor", "Plate")
    assert.are.same({ "500", "700", "950" }, VisibleKeys())
    assert.is_true(components.filterDropdown.ResetButton.shown)

    Pick("Category", "Armor", "All Armor")
    assert.are.same({ "500", "600", "700", "950", "1000" }, VisibleKeys())
    assert.are.equal("Filters: Armor", FilterLine())

    Pick("Category", "Armor", "Relics", "All Relics")
    assert.are.same({ "1000" }, VisibleKeys())
    assert.are.equal("Filters: Armor > Relics", FilterLine())

    Pick("Category", "Weapon", "One-Handed", "One-Handed Swords")
    assert.are.same({ "equip:800:12722" }, VisibleKeys())
    assert.are.equal("Filters: Weapon > One-Handed Swords", FilterLine())

    Pick("Category", "Weapon", "One-Handed", "All One-Handed")
    assert.are.same({ "equip:800:12722" }, VisibleKeys())

    Pick("Category", "All categories")
    assert.are.equal(7, #VisibleKeys())
    assert.is_false(components.filterDropdown.ResetButton.shown)
  end)

  it("keeps a group of subcategories whole when its other subcategories are scanned later", function()
    setfenv(1, environment)
    Pick("Category", "Weapon", "One-Handed", "All One-Handed")
    assert.are.same({ "equip:800:12722" }, VisibleKeys())

    AddItem("1100", { name = "Kris", class = { 2, 15 }, equipLoc = "INVTYPE_WEAPON", market = 40000, age = 3600 })
    harness.ns.DatabaseIndex.Invalidate()
    harness.RunAllTimers()
    assert.are.same({ "equip:800:12722", "1100" }, VisibleKeys())
  end)

  it("combines slots and rarities, counting robes as chest pieces", function()
    setfenv(1, environment)
    Pick("Slot", "Armor", "Chest")
    assert.are.same({ "600", "700" }, VisibleKeys())
    assert.is_true(components.filterDropdown.ResetButton.shown)
    Pick("Slot", "Armor", "Head")
    assert.are.same({ "500", "600", "700", "950" }, VisibleKeys())
    Pick("Slot", "Weapons", "Relic")
    assert.are.same({ "500", "600", "700", "950", "1000" }, VisibleKeys())
    Pick("Slot", "Weapons", "Relic")

    Pick("Rarity", "Epic")
    assert.are.same({ "500", "600" }, VisibleKeys())
    assert.are.equal("Filters: Chest, Head · Epic", FilterLine())

    -- Once loaded, the waiting helm turns out to be epic too.
    harness.itemInfo[950] = { "Helm of Valor", "item:950", 4, 60, 55 }
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 950, true)
    harness.RunAllTimers()
    assert.are.same({ "500", "600", "950" }, VisibleKeys())
    assert.are.equal("Filters: Chest, Head · Epic", FilterLine())

    Pick("Slot", "Armor", "Chest")
    Pick("Slot", "Armor", "Head")
    assert.is_true(components.filterDropdown.ResetButton.shown)
    Pick("Rarity", "Epic")
    assert.are.equal(7, #VisibleKeys())
    assert.is_false(components.filterDropdown.ResetButton.shown)
  end)

  it("offers the stats found on gear, grouped, leaving out base armor and weapon damage", function()
    setfenv(1, environment)
    local stats = Entry(components.filterDropdown:OpenMenu(), "Stats")
    assert.are.same({ "Attributes", "Offense", "Resistances", "Other" }, Labels(stats))
    assert.are.same({ "Strength", "Stamina", "Intellect", "Spirit" }, Labels(Entry(stats, "Attributes")))
    assert.are.same({ "Attack Power" }, Labels(Entry(stats, "Offense")))
    assert.are.same({ "Fire Resistance" }, Labels(Entry(stats, "Resistances")))
    assert.are.same({ "ITEM_MOD_MYSTERY_SHORT" }, Labels(Entry(stats, "Other")))
  end)

  it("keeps gear with every chosen stat, including items that finish loading later", function()
    setfenv(1, environment)
    Pick("Stats", "Attributes", "Strength")
    assert.are.same({ "500", "700", "equip:800:12722" }, VisibleKeys())
    assert.is_true(components.filterDropdown.ResetButton.shown)

    Pick("Stats", "Attributes", "Stamina")
    assert.are.equal("Filters: Stamina + Strength", FilterLine())
    assert.are.equal(3, #VisibleKeys())
    Pick("Stats", "Resistances", "Fire Resistance")
    assert.are.same({ "700" }, VisibleKeys())
    Pick("Stats", "Resistances", "Fire Resistance")

    harness.itemInfo[950] = { "Helm of Valor", "item:950", 4, 60, 55 }
    harness.itemStats[950] = { ITEM_MOD_STRENGTH_SHORT = 7, ITEM_MOD_STAMINA_SHORT = 3, ITEM_MOD_AGILITY_SHORT = 4 }
    harness.FireEvent("GET_ITEM_INFO_RECEIVED", 950, true)
    harness.RunAllTimers()
    assert.are.same({ "500", "700", "950", "equip:800:12722" }, VisibleKeys())
    -- A stat first seen on an item that just loaded joins the menu.
    local attributes = Entry(Entry(components.filterDropdown:OpenMenu(), "Stats"), "Attributes")
    assert.are.same({ "Strength", "Agility", "Stamina", "Intellect", "Spirit" }, Labels(attributes))

    components.filterDropdown.ResetButton:Click()
    assert.are.equal(7, #VisibleKeys())
  end)

  it("shows the rows before reading gear stats, then fills in the Stats filter", function()
    setfenv(1, environment)
    Pick("Stats", "Attributes", "Strength")
    local GetItemStats, statsReads = C_Item.GetItemStats, 0
    C_Item.GetItemStats = function(...)
      statsReads = statsReads + 1
      return GetItemStats(...)
    end

    local previous = harness.ns.DatabaseIndex.Get().rows
    harness.ns.DatabaseIndex.Invalidate()
    repeat
      harness.RunTimers()
    until harness.ns.DatabaseIndex.Get().rows ~= previous
    assert.are.equal(0, statsReads)

    harness.RunAllTimers()
    assert.is_true(statsReads > 0)
    assert.are.same({ "500", "700", "equip:800:12722" }, VisibleKeys())
  end)

  it("filters by required level, item level, and Market Value in gold", function()
    setfenv(1, environment)
    local frame = ShowRange("Required Level", NewRangeFrame())
    assert.are.equal(3, frame.MinLevel.letters)
    frame:Type(50, 60)
    assert.are.same({ "500", "600", "1000" }, VisibleKeys())
    assert.is_true(components.filterDropdown.ResetButton.shown)
    assert.are.equal("Filters: Required Level 50-60", FilterLine())

    ShowRange("Item Level", NewRangeFrame()):Type(63, 0)
    assert.are.same({ "500" }, VisibleKeys())
    assert.are.equal("Filters: Required Level 50-60 · Item Level 63+", FilterLine())

    components.filterDropdown.ResetButton:Click()
    frame = ShowRange("Market Value (gold)", NewRangeFrame())
    assert.are.equal(5, frame.MaxLevel.letters)
    frame:Type(25, 150)
    assert.are.same({ "600", "700" }, VisibleKeys())
    assert.are.equal("Filters: Market Value (gold) 25-150", FilterLine())
    frame:Type(0, 10)
    assert.are.same({ "950", "equip:800:12722", "1000", "900" }, VisibleKeys())
    assert.are.equal("Filters: Market Value (gold) up to 10", FilterLine())
  end)

  it("shows each range's own bounds when the menu reuses an input frame", function()
    setfenv(1, environment)
    local pooled = NewRangeFrame()
    ShowRange("Required Level", pooled):Type(50, 60)

    ShowRange("Item Level", pooled)
    assert.are.same({ 0, 0 }, { pooled.MinLevel.value, pooled.MaxLevel.value })
    assert.are.same({ "500", "600", "1000" }, VisibleKeys())

    ShowRange("Required Level", pooled)
    assert.are.same({ 50, 60 }, { pooled.MinLevel.value, pooled.MaxLevel.value })
  end)

  it("keeps items you can craft, or only those profitable after the Auction House cut", function()
    setfenv(1, environment)
    Pick("Crafting", "Only items I can craft")
    assert.are.same({ "500", "600", "900" }, VisibleKeys())
    assert.are.equal("Filters: Craftable", FilterLine())

    local profitable = Entry(Entry(components.filterDropdown:OpenMenu(), "Crafting"), "Only profitable crafts")
    assert.are.equal(
      "Items whose Market Value, less the 5% Auction House cut, is above their Craft Cost.",
      profitable.tooltipText
    )
    Pick("Crafting", "Only profitable crafts")
    assert.are.equal("Filters: Profitable crafts", FilterLine())
    assert.are.equal(1, #VisibleKeys())
    Pick("Crafting", "Only items I can craft")
    assert.are.same({ "500" }, VisibleKeys())
    assert.are.equal("Filters: Profitable crafts", FilterLine())
  end)

  it("keeps items from the latest scan or seen within a number of days", function()
    setfenv(1, environment)
    Pick("Last Seen", "In the latest scan")
    assert.are.same({ "500", "700", "900" }, VisibleKeys())
    assert.are.equal("Filters: In the latest scan", FilterLine())

    Pick("Last Seen", "Seen in the last 3 days")
    assert.are.same({ "500", "700", "950", "900" }, VisibleKeys())

    Pick("Last Seen", "Seen in the last 7 days")
    assert.are.same({ "500", "600", "700", "950", "1000", "900" }, VisibleKeys())

    Pick("Last Seen", "Any time")
    assert.are.equal(7, #VisibleKeys())
    assert.is_false(components.filterDropdown.ResetButton.shown)
    assert.are.equal("", FilterLine())
  end)

  it("hides uncertain prices and resets every filter at once", function()
    setfenv(1, environment)
    Pick("Hide uncertain prices")
    assert.is_true(components.filterDropdown.ResetButton.shown)
    Pick("Category", "Armor", "All Armor")
    assert.are.same({ "500", "600", "950", "1000" }, VisibleKeys())
    assert.are.equal("Filters: Armor · Certain prices", FilterLine())

    components.filterDropdown.ResetButton:Click()
    assert.are.equal(7, #VisibleKeys())
    assert.is_false(components.filterDropdown.ResetButton.shown)
  end)

  it("keeps every filter after a reload until they are reset", function()
    setfenv(1, environment)
    Pick("Category", "Armor", "Plate")
    Pick("Slot", "Armor", "Head")
    Pick("Rarity", "Epic")
    Pick("Stats", "Attributes", "Strength")
    ShowRange("Required Level", NewRangeFrame()):Type(50, 0)
    Pick("Crafting", "Only profitable crafts")
    Pick("Last Seen", "Seen in the last 7 days")
    Pick("Hide uncertain prices")
    local line = "Filters: Armor > Plate · Head · Epic · Strength · Required Level 50+"
      .. " · Profitable crafts · Seen in the last 7 days · Certain prices"
    assert.are.equal(line, FilterLine())
    assert.are.same({ "500" }, VisibleKeys())

    Reload()
    assert.are.equal(line, FilterLine())
    assert.are.same({ "500" }, VisibleKeys())
    assert.is_true(components.filterDropdown.ResetButton.shown)
    local menu = components.filterDropdown:OpenMenu()
    assert.is_true(Entry(Entry(Entry(menu, "Category"), "Armor"), "Plate").IsSelected())
    assert.is_true(Entry(Entry(menu, "Last Seen"), "Seen in the last 7 days").IsSelected())
    local range = ShowRange("Required Level", NewRangeFrame())
    assert.are.same({ 50, 0 }, { range.MinLevel.value, range.MaxLevel.value })

    components.filterDropdown.ResetButton:Click()
    Reload()
    assert.are.equal("", FilterLine())
    assert.are.equal(7, #VisibleKeys())
    assert.is_false(components.filterDropdown.ResetButton.shown)
  end)

  it("drops saved filters that are no longer valid and keeps the rest", function()
    setfenv(1, environment)
    StartSession({
      databaseFilters = {
        category = { key = "4:4", classID = "4", path = "Armor > Plate" },
        slots = { Head = true, Chest = "yes", [3] = true },
        qualities = { [4] = true, Epic = true },
        stats = "Strength",
        ranges = {
          requiredLevel = { min = -5, max = 60 },
          itemLevel = "63",
          marketValue = { min = 25, max = "lots" },
          retired = { min = 1, max = 2 },
        },
        craftable = "yes",
        freshness = 9,
        hideUncertain = true,
      },
    })
    assert.are.equal(
      "Filters: Head · Epic · Required Level up to 60 · Market Value (gold) 25+ · Certain prices",
      FilterLine()
    )
    assert.are.same({ "500" }, VisibleKeys())

    for _, saved in ipairs({
      "old",
      { category = "Armor", slots = "Head", ranges = "50-60", freshness = "2", profitable = 1 },
      { category = { key = "2:One-Handed", classID = 2, subClassIDs = { [7] = "yes" }, path = "Weapon > One-Handed" } },
      { category = { key = "2", classID = 2, subClassIDs = "7", path = "Weapon" }, freshness = 1.5 },
    }) do
      StartSession({ databaseFilters = saved })
      assert.are.equal("", FilterLine())
      assert.are.equal(7, #VisibleKeys())
    end
  end)
end)

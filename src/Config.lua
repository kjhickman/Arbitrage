local _, ns = ...

ns.Config = {}

---@class ArbitrageConfig
---@field showVendor boolean
---@field showMarketValue boolean
---@field showBuyout boolean
---@field showListed boolean
---@field showSaleRate boolean
---@field showAverageSalePrice boolean
---@field showCraftingCost boolean
---@field showMinimumCraftCost boolean
---@field showCraftProfit boolean
---@field tooltipDetails "compact"|"shift"|"always"
---@field showCraftingWindowProfits boolean
---@field craftingWindowMinimumProfit number copper; zero shows all known profits, including losses
---@field showOpportunitySkillUpIcons boolean
---@field showUncertainOpportunities boolean
---@field minimumProfit number copper; Auction House threshold; zero lists every known craft
---@field opportunityProfession string empty for every profession
---@field opportunityCrafter string empty for every character, or ns.Config.CURRENT_CHARACTER
---@field opportunitySaleMethod ""|"auction"|"vendor" empty for either
---@field databaseFilters table ArbitrageDatabaseFilterState, whose shape DatabaseFilters checks
---@field showMinimapButton boolean
---@field minimapButton table LibDBIcon's saved state for the minimap button, such as its position
---@field scanWorkBudget number milliseconds a scan, or reading the Database tab's prices, may work each frame
---@field rechooseOnRefresh boolean Refresh Prices also makes or buys each shopping list material as costs least
---@field hideFinishedMaterials boolean the shopping list leaves out materials you have all you need of

---@type ArbitrageConfig!
local config

---@type ArbitrageConfig
local defaults = {
  showVendor = true,
  showMarketValue = true,
  showBuyout = true,
  showListed = false,
  showSaleRate = true,
  showAverageSalePrice = false,
  showCraftingCost = true,
  showMinimumCraftCost = true,
  showCraftProfit = false,
  tooltipDetails = "shift",
  showCraftingWindowProfits = true,
  craftingWindowMinimumProfit = 1,
  showOpportunitySkillUpIcons = true,
  showUncertainOpportunities = true,
  minimumProfit = 1,
  opportunityProfession = "",
  opportunityCrafter = "",
  opportunitySaleMethod = "",
  -- Shared by every config that lacks saved filters, so it is never changed in place;
  -- DatabaseFilters saves a table of its own.
  databaseFilters = {},
  showMinimapButton = false,
  scanWorkBudget = 10,
  rechooseOnRefresh = true,
  hideFinishedMaterials = false,
}

local optionsCategory

local DETAIL_MODES = {
  compact = true,
  shift = true,
  always = true,
}

local SALE_METHODS = {
  [""] = true,
  auction = true,
  vendor = true,
}

-- Copper, on a 1-2-5 scale from two silver to a hundred gold, below which zero lists every
-- craft and one asks only that it turns a profit. Presets rather than a slider because a linear
-- slider cannot offer silver-sized thresholds and a useful ceiling at once.
ns.Config.MINIMUM_PROFIT_CHOICES =
  { 0, 1, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000, 200000, 500000, 1000000 }
local MINIMUM_PROFIT_LABELS = { [0] = "Show all crafts", [1] = "Any profit" }

-- The crafter filter value that follows whichever character is logged in; never a character name.
ns.Config.CURRENT_CHARACTER = "@current"

local MINIMUM_PROFIT_VALUES = {}
for _, copper in ipairs(ns.Config.MINIMUM_PROFIT_CHOICES) do
  MINIMUM_PROFIT_VALUES[copper] = true
end

-- Milliseconds a scan may work each frame while it reads and prices auctions, and the Database tab
-- while it reads the price database. More finishes sooner and lowers the frame rate until it does.
local SCAN_WORK_BUDGET_CHOICES = { 4, 6, 8, 10, 12, 16, 20 }
local SCAN_WORK_BUDGET_LABELS = { [4] = "4 ms (smoothest)", [10] = "10 ms (default)", [20] = "20 ms (fastest)" }

local SCAN_WORK_BUDGET_VALUES = {}
for _, milliseconds in ipairs(SCAN_WORK_BUDGET_CHOICES) do
  SCAN_WORK_BUDGET_VALUES[milliseconds] = true
end

function ns.Config.Init()
  if type(ARBITRAGE_CONFIG) ~= "table" then
    ARBITRAGE_CONFIG = {}
  end

  -- Both windows used the same minimum-profit threshold before they were split.
  if ARBITRAGE_CONFIG.craftingWindowMinimumProfit == nil then
    ARBITRAGE_CONFIG.craftingWindowMinimumProfit = ARBITRAGE_CONFIG.minimumProfit
  end

  for key, value in pairs(defaults) do
    if
      type(ARBITRAGE_CONFIG[key]) ~= type(value)
      or (key == "tooltipDetails" and not DETAIL_MODES[ARBITRAGE_CONFIG[key]])
      or (key == "opportunitySaleMethod" and not SALE_METHODS[ARBITRAGE_CONFIG[key]])
      or ((key == "minimumProfit" or key == "craftingWindowMinimumProfit") and not MINIMUM_PROFIT_VALUES[ARBITRAGE_CONFIG[key]])
      or (key == "scanWorkBudget" and not SCAN_WORK_BUDGET_VALUES[ARBITRAGE_CONFIG[key]])
    then
      ARBITRAGE_CONFIG[key] = value
    end
  end
  -- Not a default, since LibDBIcon writes the button's position into it.
  if type(ARBITRAGE_CONFIG.minimapButton) ~= "table" then
    ARBITRAGE_CONFIG.minimapButton = {}
  end
  if ARBITRAGE_CONFIG.showTooltips == false then
    ARBITRAGE_CONFIG.showMarketValue = false
    ARBITRAGE_CONFIG.showBuyout = false
    ARBITRAGE_CONFIG.showCraftingCost = false
    ARBITRAGE_CONFIG.showMinimumCraftCost = false
  end
  ARBITRAGE_CONFIG.showTooltips = nil
  -- The vendor profit tooltip lines gave way to Craft Profit.
  ARBITRAGE_CONFIG.showVendorProfit = nil
  ARBITRAGE_CONFIG.showMinimumVendorProfit = nil
  ARBITRAGE_CONFIG.includeBestCaseOnly = nil
  ---@cast ARBITRAGE_CONFIG ArbitrageConfig
  config = ARBITRAGE_CONFIG
end

---@param key keyof ArbitrageConfig
---@return boolean|string|number|table
function ns.Config.Get(key)
  return config[key]
end

---@alias ArbitrageOpportunityFilterKey "minimumProfit"|"showUncertainOpportunities"|"opportunityProfession"|"opportunityCrafter"|"opportunitySaleMethod"

---@param key ArbitrageOpportunityFilterKey|"databaseFilters"|"rechooseOnRefresh"|"hideFinishedMaterials"
---@param value boolean|number|string|table
function ns.Config.Set(key, value)
  config[key] = value
end

---@param key ArbitrageOpportunityFilterKey
---@return boolean
function ns.Config.IsDefault(key)
  return config[key] == defaults[key]
end

---@param key ArbitrageOpportunityFilterKey
function ns.Config.Reset(key)
  config[key] = defaults[key]
end

local function RegisterSetting(category, key, variableType, label)
  return Settings.RegisterAddOnSetting(category, "Arbitrage_" .. key, key, config, variableType, label, defaults[key])
end

local function CreateMinimumProfitOptions()
  local container = Settings.CreateControlTextContainer()
  for _, copper in ipairs(ns.Config.MINIMUM_PROFIT_CHOICES) do
    container:Add(copper, MINIMUM_PROFIT_LABELS[copper] or C_CurrencyInfo.GetCoinTextureString(copper, 10))
  end
  return container:GetData()
end

local function CreateScanWorkBudgetOptions()
  local container = Settings.CreateControlTextContainer()
  for _, milliseconds in ipairs(SCAN_WORK_BUDGET_CHOICES) do
    container:Add(milliseconds, SCAN_WORK_BUDGET_LABELS[milliseconds] or (milliseconds .. " ms"))
  end
  return container:GetData()
end

local function CreateDetailsOptions()
  local container = Settings.CreateControlTextContainer()
  -- Saved configs still say "compact", from when this choice was labelled Compact.
  container:Add("compact", "Never")
  container:Add("shift", "Hold Shift")
  container:Add("always", "Always")
  return container:GetData()
end

function ns.Config.RegisterOptionsPanel()
  local category, layout = Settings.RegisterVerticalLayoutCategory("Arbitrage")
  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Item Tooltips"))

  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showVendor", Settings.VarType.Boolean, "Show " .. ns.Terminology.vendor.label),
    ns.Terminology.vendor.definition
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showBuyout", Settings.VarType.Boolean, "Show " .. ns.Terminology.current.label),
    ns.Terminology.current.definition
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showMarketValue", Settings.VarType.Boolean, "Show " .. ns.Terminology.typical.label),
    ns.Terminology.typical.definition
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showListed", Settings.VarType.Boolean, "Show Listed"),
    "Shows how many units were listed on an average scan of the latest day your scans counted them, within the last 14 days. Hidden when none did."
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showSaleRate", Settings.VarType.Boolean, "Show Sale Rate"),
    "Shows the share of the item's auctions that sell across your region, from TradeSkillMaster through Arbitrage Companion. Hidden without the Companion's data, and on random-enchant gear."
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showAverageSalePrice", Settings.VarType.Boolean, "Show Average Sale Price"),
    "Shows the average price the item sells for across your region, from TradeSkillMaster through Arbitrage Companion. Hidden without the Companion's data, and on random-enchant gear."
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(
      category,
      "showCraftingCost",
      Settings.VarType.Boolean,
      "Show " .. ns.Terminology.typicalCraftCost.label
    ),
    ns.Terminology.typicalCraftCost.definition
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(
      category,
      "showMinimumCraftCost",
      Settings.VarType.Boolean,
      "Show " .. ns.Terminology.currentCraftCost.label
    ),
    ns.Terminology.currentCraftCost.definition
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(
      category,
      "showCraftProfit",
      Settings.VarType.Boolean,
      "Show " .. ns.Terminology.typicalProfit.label
    ),
    ns.Terminology.typicalProfit.definition
  )
  Settings.CreateDropdown(
    category,
    RegisterSetting(category, "tooltipDetails", Settings.VarType.String, "Pricing Details"),
    CreateDetailsOptions,
    ("Controls when tooltips add when a scan last listed the item and the materials for %s and %s. Never keeps tooltips to the price lines."):format(
      ns.Terminology.typicalCraftCost.label,
      ns.Terminology.currentCraftCost.label
    )
  )

  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Crafting Window"))
  local showCraftingWindowProfits =
    RegisterSetting(category, "showCraftingWindowProfits", Settings.VarType.Boolean, "Show Crafting Window Profits")
  showCraftingWindowProfits:SetValueChangedCallback(ns.CraftingWindow.Refresh)
  Settings.CreateCheckbox(
    category,
    showCraftingWindowProfits,
    "Shows each learned recipe's profit beside it in the crafting window, with its costs on mouseover."
  )
  local minimumProfit =
    RegisterSetting(category, "craftingWindowMinimumProfit", Settings.VarType.Number, "Minimum Profit")
  minimumProfit:SetValueChangedCallback(ns.CraftingWindow.Refresh)
  Settings.CreateDropdown(
    category,
    minimumProfit,
    CreateMinimumProfitOptions,
    ("Hides crafting window profits below this amount, judged on %s rather than %s. Separate from the Auction House filters; Show all crafts includes losses."):format(
      ns.Terminology.typicalProfit.label,
      ns.Terminology.currentProfit.label
    )
  )

  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Opportunities"))
  local showSkillUpIcons =
    RegisterSetting(category, "showOpportunitySkillUpIcons", Settings.VarType.Boolean, "Show Skill-Up Icons")
  showSkillUpIcons:SetValueChangedCallback(ns.OpportunityPanel.Refresh)
  Settings.CreateCheckbox(
    category,
    showSkillUpIcons,
    "Shows profession skill-up icons beside crafts in Opportunities. Skill-up details stay available on hover."
  )

  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Scans"))
  Settings.CreateDropdown(
    category,
    RegisterSetting(category, "scanWorkBudget", Settings.VarType.Number, "Scan Work Per Frame"),
    CreateScanWorkBudgetOptions,
    "How long Arbitrage works each frame while it reads and prices a scan's auctions, or reads the price database for the Database tab. Higher finishes sooner but lowers your frame rate until it's done; lower keeps the game smoother."
  )

  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Minimap"))
  local showMinimapButton =
    RegisterSetting(category, "showMinimapButton", Settings.VarType.Boolean, "Show Minimap Button")
  showMinimapButton:SetValueChangedCallback(ns.MinimapButton.Refresh)
  Settings.CreateCheckbox(
    category,
    showMinimapButton,
    "Shows an Arbitrage button on the minimap. Left-click it to open or close the Arbitrage window, right-click it to open these settings, and drag it to move it."
  )

  Settings.RegisterAddOnCategory(category)
  optionsCategory = category
end

function ns.Config.OpenOptionsPanel()
  Settings.OpenToCategory(optionsCategory:GetID())
end

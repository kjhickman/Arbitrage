local _, ns = ...

ns.Config = {}

---@class ArbitrageConfig
---@field showMarketValue boolean
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

---@type ArbitrageConfig!
local config

---@type ArbitrageConfig
local defaults = {
  showMarketValue = true,
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
      or (
        (key == "minimumProfit" or key == "craftingWindowMinimumProfit")
        and not MINIMUM_PROFIT_VALUES[ARBITRAGE_CONFIG[key]]
      )
    then
      ARBITRAGE_CONFIG[key] = value
    end
  end
  if ARBITRAGE_CONFIG.showTooltips == false then
    ARBITRAGE_CONFIG.showMarketValue = false
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

---@param key ArbitrageOpportunityFilterKey|"databaseFilters"
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
    RegisterSetting(category, "showMarketValue", Settings.VarType.Boolean, "Show Market Value"),
    "Shows the rolling 14-day low-end Auction House price of items that can be auctioned."
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showCraftingCost", Settings.VarType.Boolean, "Show Craft Cost"),
    "Shows the estimated cheapest cost to make one item from Market Values, vendor prices, and intermediate crafts."
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showMinimumCraftCost", Settings.VarType.Boolean, "Show Buyout Cost"),
    "Shows the cost to make one item with the cheapest per-unit buyouts from the latest full scan. It is not always cheaper than Craft Cost."
  )
  Settings.CreateCheckbox(
    category,
    RegisterSetting(category, "showCraftProfit", Settings.VarType.Boolean, "Show Craft Profit"),
    "Shows Market Value after the 5% Auction House cut minus Craft Cost."
  )
  Settings.CreateDropdown(
    category,
    RegisterSetting(category, "tooltipDetails", Settings.VarType.String, "Pricing Details"),
    CreateDetailsOptions,
    "Controls when tooltips add the scan data behind Market Value and the materials for Craft Cost and Buyout Cost. Never keeps tooltips to the price lines."
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
    "Hides crafting window profits below this amount, judged on the profit shown rather than Buyout Profit. Separate from the Auction House filters; Show all crafts includes losses."
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

  Settings.RegisterAddOnCategory(category)
  optionsCategory = category
end

function ns.Config.OpenOptionsPanel()
  Settings.OpenToCategory(optionsCategory:GetID())
end

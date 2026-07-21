local _, ns = ...

ns.Config = {}

---@class ArbitrageConfig
---@field showTooltips boolean
---@field showCraftingCost boolean
---@field showMinimumCraftCost boolean
---@field useAuctionatorScans boolean

---@type ArbitrageConfig!
local config

---@type ArbitrageConfig
local defaults = {
  showTooltips = true,
  showCraftingCost = true,
  showMinimumCraftCost = true,
  useAuctionatorScans = true,
}

local panel
local checkbox
local craftingCostCheckbox
local minimumCraftCheckbox
local auctionatorCheckbox

function ns.Config.Init()
  if type(ARBITRAGE_CONFIG) ~= "table" then
    ARBITRAGE_CONFIG = {}
  end

  for key, value in pairs(defaults) do
    if type(ARBITRAGE_CONFIG[key]) ~= type(value) then
      ARBITRAGE_CONFIG[key] = value
    end
  end

  ---@cast ARBITRAGE_CONFIG ArbitrageConfig
  config = ARBITRAGE_CONFIG
end

---@param key keyof ArbitrageConfig
---@return boolean
function ns.Config.Get(key)
  return config[key]
end

function ns.Config.ToggleTooltips()
  local enabled = not ns.Config.Get("showTooltips")
  config.showTooltips = enabled

  if checkbox then
    checkbox:SetChecked(enabled)
  end

  return enabled
end

---@param parent Frame
---@param name string
---@param anchor Frame
---@param key keyof ArbitrageConfig
---@param labelText string
---@return CheckButton
local function AddCheckbox(parent, name, anchor, key, labelText)
  local button = CreateFrame("CheckButton", name, parent, "InterfaceOptionsCheckButtonTemplate")
  button:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)
  button:SetChecked(ns.Config.Get(key))
  button:SetScript("OnClick", function(self)
    config[key] = self:GetChecked()
  end)

  local label = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  label:SetPoint("LEFT", button, "RIGHT", 0, 1)
  label:SetText(labelText)

  return button
end

function ns.Config.RegisterOptionsPanel()
  if panel then
    return
  end

  panel = CreateFrame("Frame", "ArbitrageOptionsPanel")
  panel.name = "Arbitrage"

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("Arbitrage")

  checkbox = CreateFrame("CheckButton", "ArbitrageTooltipCheckbox", panel, "InterfaceOptionsCheckButtonTemplate")
  checkbox:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
  checkbox:SetChecked(ns.Config.Get("showTooltips"))
  checkbox:SetScript("OnClick", function(self)
    config.showTooltips = self:GetChecked()
  end)

  local checkboxLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  checkboxLabel:SetPoint("LEFT", checkbox, "RIGHT", 0, 1)
  checkboxLabel:SetText("Show market and crafting values in item tooltips")

  craftingCostCheckbox = AddCheckbox(
    panel,
    "ArbitrageCraftingCostCheckbox",
    checkbox,
    "showCraftingCost",
    "Show crafting cost in item tooltips"
  )
  minimumCraftCheckbox = AddCheckbox(
    panel,
    "ArbitrageMinimumCraftCheckbox",
    craftingCostCheckbox,
    "showMinimumCraftCost",
    "Show minimum craft cost in item tooltips"
  )
  auctionatorCheckbox = AddCheckbox(
    panel,
    "ArbitrageAuctionatorCheckbox",
    minimumCraftCheckbox,
    "useAuctionatorScans",
    "Use Auctionator full scans"
  )

  panel:SetScript("OnShow", function()
    checkbox:SetChecked(ns.Config.Get("showTooltips"))
    craftingCostCheckbox:SetChecked(ns.Config.Get("showCraftingCost"))
    minimumCraftCheckbox:SetChecked(ns.Config.Get("showMinimumCraftCost"))
    auctionatorCheckbox:SetChecked(ns.Config.Get("useAuctionatorScans"))
  end)

  local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
  Settings.RegisterAddOnCategory(category)
end

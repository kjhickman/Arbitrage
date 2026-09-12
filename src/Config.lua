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
local checkboxes = {}

local OPTIONS = {
  { "showTooltips", "ArbitrageTooltipCheckbox", "Show market and crafting values in item tooltips" },
  { "showCraftingCost", "ArbitrageCraftingCostCheckbox", "Show crafting cost in item tooltips" },
  { "showMinimumCraftCost", "ArbitrageMinimumCraftCheckbox", "Show minimum craft cost in item tooltips" },
  { "useAuctionatorScans", "ArbitrageAuctionatorCheckbox", "Use Auctionator full scans" },
}

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

  if checkboxes.showTooltips then
    checkboxes.showTooltips:SetChecked(enabled)
  end

  return enabled
end

---@param parent Frame
---@param name string
---@param anchor Region
---@param key keyof ArbitrageConfig
---@param labelText string
---@param offset number
---@return CheckButton
local function AddCheckbox(parent, name, anchor, key, labelText, offset)
  local button = CreateFrame("CheckButton", name, parent, "InterfaceOptionsCheckButtonTemplate")
  button:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, offset)
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

  local anchor = title
  for index, option in ipairs(OPTIONS) do
    local key = option[1]
    local offset = index == 1 and -16 or -8
    local button = AddCheckbox(panel, option[2], anchor, key, option[3], offset)
    checkboxes[key] = button
    anchor = button
  end

  panel:SetScript("OnShow", function()
    for key, button in pairs(checkboxes) do
      button:SetChecked(ns.Config.Get(key))
    end
  end)

  local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
  Settings.RegisterAddOnCategory(category)
end

local addonName, ns = ...

local frame = CreateFrame("Frame")

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

local function Noop() end

---@param groups table<string, ArbitrageMarketRecord[]>
---@param latestBuyouts table<string, number>
---@param entry ArbitrageScanEntry
local function AccumulateAuction(groups, latestBuyouts, entry)
  local unitPrice = math.ceil(entry.buyout / entry.quantity)

  for _, dbKey in ipairs(ns.Keys.FromLink(entry.itemLink)) do
    groups[dbKey] = groups[dbKey] or {}
    groups[dbKey][#groups[dbKey] + 1] = {
      price = unitPrice,
      quantity = entry.quantity,
    }
    latestBuyouts[dbKey] = math.min(latestBuyouts[dbKey] or unitPrice, unitPrice)
  end
end

---@param scanEntries ArbitrageScanEntry[]?
---@param rawEntryCount number?
---@param checkpoint fun()?
local function ProcessFullScan(scanEntries, rawEntryCount, checkpoint)
  if type(scanEntries) ~= "table" then
    Print("Full scan had no raw data")
    return
  end
  checkpoint = checkpoint or Noop
  ---@type table<string, ArbitrageMarketRecord[]>
  local groups = {}
  ---@type table<string, number>
  local latestBuyouts = {}

  for _, entry in ipairs(scanEntries) do
    AccumulateAuction(groups, latestBuyouts, entry)
    checkpoint()
  end
  if rawEntryCount and rawEntryCount > 0 and next(groups) == nil then
    Print("Full scan contained no usable auctions; previous data kept")
    return
  end

  local results = ns.MarketValue.CalculateAll(groups, checkpoint)
  local count = ns.Database.SaveScan(results, time(), latestBuyouts, checkpoint)

  ns.AuctionHouse.Refresh()
  Print("Full scan done: stored market prices for " .. count .. " items")
end

local function RegisterSlashCommands()
  SLASH_ARBITRAGE1 = "/arb"

  local function PrintHelp()
    Print("/arb help - Show all commands")
    Print("/arb status - Show stored data and settings status")
    Print("/arb settings - Open Arbitrage settings")
  end

  SlashCmdList.ARBITRAGE = function(message)
    local command = strlower(strtrim(message or ""))

    if command == "status" then
      local status = ns.Database.GetStatus()
      local recipeStatus = ns.RecipeBook.GetStatus()
      Print("Stored items: " .. status.itemCount)
      Print("Known vendor prices: " .. ns.Database.CountVendorPrices())
      Print("Known recipes: " .. recipeStatus.recipeCount .. " across " .. recipeStatus.characterCount .. " characters")
      Print("Tooltips: " .. (ns.Config.Get("showTooltips") and "enabled" or "disabled"))
      Print("Crafting cost: " .. (ns.Config.Get("showCraftingCost") and "enabled" or "disabled"))
      Print("Minimum craft cost: " .. (ns.Config.Get("showMinimumCraftCost") and "enabled" or "disabled"))
      local latestScan = status.latestScan and tostring(date("%Y-%m-%d %H:%M", status.latestScan)) or "unknown"
      Print("Latest scan: " .. latestScan)
      Print("Scans in last 14 days: " .. status.recentScanCount)
    elseif command == "settings" then
      ns.Config.OpenOptionsPanel()
    else
      PrintHelp()
    end
  end
end

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, eventName, loadedAddonName)
  if eventName ~= "ADDON_LOADED" or loadedAddonName ~= addonName then
    return
  end

  ns.Config.Init()
  ns.Database.Init()
  ns.RecipeBook.Init()
  ns.Scan.Init(ProcessFullScan)
  ns.AuctionHouse.Register()
  ns.Vendor.Register()
  ns.RecipeCapture.Register()
  ns.Tooltip.Register()
  RegisterSlashCommands()
  ns.Config.RegisterOptionsPanel()
  frame:UnregisterEvent("ADDON_LOADED")
end)

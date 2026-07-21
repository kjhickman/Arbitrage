local addonName, ns = ...

local frame = CreateFrame("Frame")

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

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
local function ProcessFullScan(scanEntries, rawEntryCount)
  if type(scanEntries) ~= "table" then
    Print("Full scan had no raw data")
    return
  end
  if rawEntryCount and rawEntryCount > 0 and #scanEntries == 0 then
    Print("Full scan contained no usable auctions; previous data kept")
    return
  end

  ---@type table<string, ArbitrageMarketRecord[]>
  local groups = {}
  ---@type table<string, number>
  local latestBuyouts = {}

  for _, entry in ipairs(scanEntries) do
    AccumulateAuction(groups, latestBuyouts, entry)
  end
  if rawEntryCount and rawEntryCount > 0 and next(groups) == nil then
    Print("Full scan contained no usable auctions; previous data kept")
    return
  end

  local results = ns.MarketValue.CalculateAll(groups)
  local count = ns.Database.SaveScan(results, time(), latestBuyouts)

  Print("Stored market prices for " .. count .. " items")
end

local function RegisterSlashCommands()
  SLASH_ARBITRAGE1 = "/arb"
  SLASH_ARBITRAGE2 = "/arbitrage"

  SlashCmdList.ARBITRAGE = function(message)
    local command, argument = strtrim(message or ""):match("^(%S*)%s*(.*)$")
    command = strlower(command or "")

    if command == "count" then
      Print("Stored items: " .. ns.Database.Count())
    elseif command == "scan" then
      ns.Scan.Start()
    elseif command == "status" then
      local status = ns.Database.GetStatus()
      local recipeStatus = ns.RecipeBook.GetStatus()
      Print("Stored items: " .. status.itemCount)
      Print("Known vendor prices: " .. ns.Database.CountVendorPrices())
      Print("Known recipes: " .. recipeStatus.recipeCount .. " across " .. recipeStatus.characterCount .. " characters")
      Print("Tooltips: " .. (ns.Config.Get("showTooltips") and "enabled" or "disabled"))
      local latestScan = status.latestScan and tostring(date("%Y-%m-%d %H:%M", status.latestScan)) or "unknown"
      Print("Latest scan: " .. latestScan)
      Print("Scans in last 14 days: " .. status.recentScanCount)
    elseif command == "tooltip" then
      local enabled = ns.Config.ToggleTooltips()
      Print("Tooltips: " .. (enabled and "enabled" or "disabled"))
    elseif command == "recipes" then
      local status = ns.RecipeBook.GetStatus()
      Print("Known recipes: " .. status.recipeCount .. " across " .. status.characterCount .. " characters")
    elseif command == "item" and argument and argument ~= "" then
      local result = ns.RollingMarketValue.Get({ argument })
      if result then
        local suffix = result.isUncertain and " ?" or ""
        Print(
          argument
            .. ": "
            .. result.value
            .. suffix
            .. " ("
            .. result.dayCount
            .. " days, "
            .. result.scanCount
            .. " scans)"
        )
      else
        Print(argument .. ": no market price stored")
      end
    else
      Print("Commands: /arb scan, /arb status, /arb count, /arb item <dbKey>, /arb recipes, /arb tooltip")
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
  ns.Scan.RegisterAuctionator()
  ns.Vendor.Register()
  ns.RecipeCapture.Register()
  ns.Tooltip.Register()
  RegisterSlashCommands()
  ns.Config.RegisterOptionsPanel()
  frame:UnregisterEvent("ADDON_LOADED")
end)

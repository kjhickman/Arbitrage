local addonName, ns = ...

local frame = CreateFrame("Frame")
local DETAIL_MODE_LABELS = {
  compact = "Compact",
  shift = "Hold Shift",
  always = "Always",
}

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

local function Noop() end

---@param groups table<string, ArbitrageMarketRecord[]>
---@param latestBuyouts table<string, number>
---@param entry ArbitrageScanEntry
local function AccumulateAuction(groups, latestBuyouts, entry)
  local unitPrice = math.ceil(entry.buyout / entry.quantity)
  local dbKeys = entry.itemLink and ns.Keys.FromLink(entry.itemLink) or ns.Keys.FromItemID(entry.itemID)

  for _, dbKey in ipairs(dbKeys) do
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
  ns.CraftingWindow.Refresh()
  Print("Full scan done: stored market prices for " .. count .. " items")
end

local function RegisterSlashCommands()
  SLASH_ARBITRAGE1 = "/arb"

  local function PrintHelp()
    Print("/arb help - Show all commands")
    Print("/arb status - Show stored data and settings status")
    Print("/arb settings - Open Arbitrage settings")
    Print("/arb forget <character> - Remove stored recipes for a character")
  end

  local function FormatKnownCharacters()
    local names = ns.RecipeBook.GetCharacterNames()
    if #names == 0 then
      return "no stored characters on this realm"
    end
    return "known: " .. table.concat(names, ", ")
  end

  SlashCmdList.ARBITRAGE = function(message)
    local trimmed = strtrim(message or "")
    local verb, rest = trimmed:match("^(%S+)%s*(.-)$")
    local command = strlower(verb or "")
    local argument = strtrim(rest or "")

    if command == "status" and argument == "" then
      local status = ns.Database.GetStatus()
      local recipeStatus = ns.RecipeBook.GetStatus()
      Print("Stored items: " .. status.itemCount)
      Print("Known vendor prices: " .. ns.Database.CountVendorPrices())
      Print("Known recipes: " .. recipeStatus.recipeCount .. " across " .. recipeStatus.characterCount .. " characters")
      Print("Item tooltips: " .. (ns.Config.Get("showTooltips") and "enabled" or "disabled"))
      Print("Market Value: " .. (ns.Config.Get("showMarketValue") and "shown" or "hidden"))
      Print("Crafting Cost: " .. (ns.Config.Get("showCraftingCost") and "shown" or "hidden"))
      Print("Best-case Crafting Cost: " .. (ns.Config.Get("showMinimumCraftCost") and "shown" or "hidden"))
      local detailMode = ns.Config.Get("tooltipDetails")
      ---@cast detailMode "compact"|"shift"|"always"
      Print("Pricing details: " .. DETAIL_MODE_LABELS[detailMode])
      Print("Best-case-only opportunities: " .. (ns.Config.Get("includeBestCaseOnly") and "included" or "hidden"))
      Print("Uncertain opportunities: " .. (ns.Config.Get("showUncertainOpportunities") and "shown" or "hidden"))
      local latestScan = status.latestScan and tostring(date("%Y-%m-%d %H:%M", status.latestScan)) or "unknown"
      Print("Latest scan: " .. latestScan)
      Print("Scans in last 14 days: " .. status.recentScanCount)
    elseif command == "settings" and argument == "" then
      ns.Config.OpenOptionsPanel()
    elseif command == "forget" then
      if argument == "" then
        Print("Usage: /arb forget <character> (" .. FormatKnownCharacters() .. ")")
        return
      end
      local removed = ns.RecipeBook.ForgetCharacter(argument)
      if removed then
        ns.AuctionHouse.Refresh()
        ns.CraftingWindow.Refresh()
        Print("Removed stored recipes for " .. removed)
      else
        Print("No stored recipes for " .. argument .. " (" .. FormatKnownCharacters() .. ")")
      end
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
  ns.CraftingWindow.Register()
  ns.Tooltip.Register()
  RegisterSlashCommands()
  ns.Config.RegisterOptionsPanel()
  frame:UnregisterEvent("ADDON_LOADED")
end)

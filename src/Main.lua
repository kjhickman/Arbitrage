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

local function FormatMinimumProfit(value)
  return value > 0 and C_CurrencyInfo.GetCoinTextureString(value, 10) or "none, all crafts shown"
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

---@alias ArbitragePricingCheckpoint fun(completed: number?, total: number?)

---@param checkpoint ArbitrageScanCheckpoint
---@param from number
---@param to number
---@return ArbitragePricingCheckpoint
local function PricingCheckpoint(checkpoint, from, to)
  return function(completed, total)
    if completed and total and total > 0 then
      checkpoint(from + (to - from) * (completed / total))
    else
      checkpoint()
    end
  end
end

---@param scanEntries ArbitrageScanEntry[]?
---@param rawEntryCount number?
---@param checkpoint ArbitrageScanCheckpoint?
---@return string outcome for the scan to report
local function ProcessFullScan(scanEntries, rawEntryCount, checkpoint)
  if type(scanEntries) ~= "table" then
    return "Full scan had no raw data"
  end
  checkpoint = checkpoint or Noop
  ---@type table<string, ArbitrageMarketRecord[]>
  local groups = {}
  ---@type table<string, number>
  local latestBuyouts = {}

  -- These ranges divide the bar by work stage, not by estimated wall time.
  local groupCheckpoint = PricingCheckpoint(checkpoint, 0, 20)
  local entryCount = #scanEntries
  for index, entry in ipairs(scanEntries) do
    AccumulateAuction(groups, latestBuyouts, entry)
    groupCheckpoint(index, entryCount)
  end
  if rawEntryCount and rawEntryCount > 0 and next(groups) == nil then
    return "Full scan contained no usable auctions; previous data kept"
  end

  checkpoint(20)
  local results = ns.MarketValue.CalculateAll(groups, PricingCheckpoint(checkpoint, 20, 99))
  -- Hold at 99% while committing the scan and refreshing the results.
  checkpoint(99)
  local count = ns.Database.SaveScan(results, time(), latestBuyouts, checkpoint)

  ns.OpportunityPanel.Refresh()
  ns.CraftingWindow.Refresh()
  ns.DatabaseIndex.Invalidate()
  return "Full scan done: stored market prices for " .. count .. " items"
end

local function RegisterSlashCommands()
  SLASH_ARBITRAGE1 = "/arb"

  local function PrintHelp()
    Print("/arb - Toggle the Arbitrage window")
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

    if command == "" then
      ns.Window.Toggle()
    elseif command == "status" and argument == "" then
      local status = ns.Database.GetStatus()
      local recipeStatus = ns.RecipeBook.GetStatus()
      Print("Stored items: " .. status.itemCount)
      Print("Known vendor prices: " .. ns.Database.CountVendorPrices())
      Print("Known recipes: " .. recipeStatus.recipeCount .. " across " .. recipeStatus.characterCount .. " characters")
      Print("Market Value: " .. (ns.Config.Get("showMarketValue") and "shown" or "hidden"))
      Print("Craft Cost: " .. (ns.Config.Get("showCraftingCost") and "shown" or "hidden"))
      Print("Buyout Cost: " .. (ns.Config.Get("showMinimumCraftCost") and "shown" or "hidden"))
      Print("Craft Profit: " .. (ns.Config.Get("showCraftProfit") and "shown" or "hidden"))
      local detailMode = ns.Config.Get("tooltipDetails")
      ---@cast detailMode "compact"|"shift"|"always"
      Print("Pricing details: " .. DETAIL_MODE_LABELS[detailMode])
      Print("Crafting window profits: " .. (ns.Config.Get("showCraftingWindowProfits") and "shown" or "hidden"))
      Print("Auction House minimum profit: " .. FormatMinimumProfit(ns.Config.Get("minimumProfit")))
      Print("Crafting window minimum profit: " .. FormatMinimumProfit(ns.Config.Get("craftingWindowMinimumProfit")))
      Print(
        "Crafts profitable only at buyout prices: " .. (ns.Config.Get("includeBestCaseOnly") and "shown" or "hidden")
      )
      Print("Uncertain opportunities: " .. (ns.Config.Get("showUncertainOpportunities") and "shown" or "hidden"))
      local latestScan = status.latestScan and ns.Time.Since(status.latestScan) or "unknown"
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
        ns.OpportunityPanel.Refresh()
        ns.CraftingWindow.Refresh()
        ns.DatabaseIndex.Invalidate()
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
  ns.OpportunityPanel.Register()
  ns.Vendor.Register()
  ns.RecipeCapture.Register()
  ns.CraftingWindow.Register()
  ns.Tooltip.Register()
  RegisterSlashCommands()
  ns.Config.RegisterOptionsPanel()
  frame:UnregisterEvent("ADDON_LOADED")
end)

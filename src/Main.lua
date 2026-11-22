local addonName, ns = ...

local frame = CreateFrame("Frame")

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

local function Noop() end

---@param groups table<string, ArbitrageMarketListings>
---@param latestBuyouts table<string, number>
---@param entry ArbitrageScanEntry
local function AccumulateAuction(groups, latestBuyouts, entry)
  local unitPrice = math.ceil(entry.buyout / entry.quantity)
  local dbKeys = entry.itemLink and ns.Keys.FromLink(entry.itemLink) or ns.Keys.FromItemID(entry.itemID)

  for _, dbKey in ipairs(dbKeys) do
    local listings = groups[dbKey]
    if not listings then
      listings = ns.MarketValue.NewListings()
      groups[dbKey] = listings
    end
    ns.MarketValue.AddListing(listings, unitPrice, entry.quantity)
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

local function RefreshPrices()
  ns.OpportunityPanel.Refresh()
  ns.CraftingWindow.Refresh()
  ns.TrainerWindow.Refresh()
  ns.DatabaseIndex.Invalidate()
end

---@param groups table<string, ArbitrageMarketListings>
---@param latestBuyouts table<string, number>
---@param rawEntryCount number?
---@param checkpoint ArbitrageScanCheckpoint?
---@return string outcome for the scan to report
local function PriceFullScan(groups, latestBuyouts, rawEntryCount, checkpoint)
  checkpoint = checkpoint or Noop
  if rawEntryCount and rawEntryCount > 0 and next(groups) == nil then
    return "Full scan contained no usable auctions; previous data kept"
  end

  local results = ns.MarketValue.CalculateAll(groups, PricingCheckpoint(checkpoint, 0, 99))
  -- Hold at 99% while committing the scan and refreshing the results.
  checkpoint(99)
  local count = ns.Database.SaveScan(results, time(), latestBuyouts, checkpoint)

  RefreshPrices()
  return "Full scan done: stored Market Values for " .. count .. " items"
end

-- Groups auctions as the scan reads them, so grouping uses the reading frames' spare budget
-- rather than frames of its own, then prices the groups once reading ends.
---@return ArbitrageFullScanPricing
local function StartFullScan()
  ---@type table<string, ArbitrageMarketListings>
  local groups = {}
  ---@type table<string, number>
  local latestBuyouts = {}

  return {
    Add = function(entry)
      AccumulateAuction(groups, latestBuyouts, entry)
    end,
    Finish = function(rawEntryCount, checkpoint)
      return PriceFullScan(groups, latestBuyouts, rawEntryCount, checkpoint)
    end,
  }
end

---@param buyouts table<string, number>
---@param observedAt number
---@return boolean saved
local function ProcessQuickScan(buyouts, observedAt)
  if not ns.Database.SaveQuickBuyouts(buyouts, observedAt) then
    return false
  end
  RefreshPrices()
  return true
end

local function RegisterSlashCommands()
  SLASH_ARBITRAGE1 = "/arb"

  local function PrintHelp()
    Print("/arb - Toggle the Arbitrage window")
    Print("/arb help - Show all commands")
    Print("/arb status - Show stored data and recent scans")
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
      Print("Last full scan: " .. (status.latestScan and ns.Time.Since(status.latestScan) or "never"))
      Print("Last quick scan: " .. (status.latestQuickScan and ns.Time.Since(status.latestQuickScan) or "never"))
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
  ns.Scan.Init(StartFullScan, ProcessQuickScan)
  ns.OpportunityPanel.Register()
  ns.Vendor.Register()
  ns.RecipeCapture.Register()
  ns.CraftingWindow.Register()
  ns.TrainerWindow.Register()
  ns.Tooltip.Register()
  ns.MinimapButton.Register()
  RegisterSlashCommands()
  ns.Config.RegisterOptionsPanel()
  frame:UnregisterEvent("ADDON_LOADED")
end)

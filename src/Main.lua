local addonName, ns = ...

local frame = CreateFrame("Frame")

local function Print(message)
  print("|cff00ccffArbitrage:|r " .. message)
end

local function Noop() end

---@alias ArbitragePricingCheckpoint fun(completed: number?, total: number?)

local function RefreshPrices()
  ns.OpportunityPanel.Refresh()
  ns.CraftingWindow.Refresh()
  ns.TrainerWindow.Refresh()
  ns.DatabaseIndex.Invalidate()
end

-- Groups auctions as the scan reads them, so grouping uses the reading frames' spare budget
-- rather than frames of its own, then prices the groups once reading ends.
---@return ArbitrageFullScanPricing
local function StartFullScan()
  ---@type table<string, ArbitrageMarketListings>
  local groups = {}
  ---@type table<string, number>
  local latestBuyouts = {}
  -- The keys of auctions without a link, worked out once per item.
  ---@type table<number, string[]>
  local itemKeys = {}

  return {
    Add = function(itemID, itemLink, quantity, buyout)
      local unitPrice = math.ceil(buyout / quantity)
      local dbKeys = itemLink and ns.Keys.FromLink(itemLink) or itemKeys[itemID]
      if not dbKeys then
        dbKeys = ns.Keys.FromItemID(itemID)
        itemKeys[itemID] = dbKeys
      end

      for _, dbKey in ipairs(dbKeys) do
        ns.MarketValue.AddListing(groups, dbKey, unitPrice, quantity)
        latestBuyouts[dbKey] = math.min(latestBuyouts[dbKey] or unitPrice, unitPrice)
      end
    end,
    Finish = function(rawEntryCount, checkpoint)
      checkpoint = checkpoint or Noop
      if rawEntryCount and rawEntryCount > 0 and next(groups) == nil then
        return "Full scan contained no usable auctions; previous data kept"
      end

      local results = ns.MarketValue.CalculateAll(groups, function(completed, total)
        checkpoint(completed and total and total > 0 and completed / total * 99 or nil)
      end)
      -- Hold at 99% while committing the scan and refreshing the results.
      checkpoint(99)
      local count = ns.Database.SaveScan(results, time(), latestBuyouts, checkpoint)

      RefreshPrices()
      return "Full scan done: stored Market Values for " .. count .. " items"
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

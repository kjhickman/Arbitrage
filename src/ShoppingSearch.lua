local _, ns = ...

ns.ShoppingSearch = {}

---@class ArbitrageSearchRequest
---@field itemID number
---@field quantity number how many the list still needs, so a search asks for more listings until it has them
---@field attempts number? how many times it's been sent
---@field token table? marks the request a timeout belongs to

---@class ArbitrageSearchTier
---@field unitPrice number
---@field quantity number not counting your own
---@field auctionID number? what isn't a commodity: the tier is a row of identical auctions, one item each, and this is the one to buy next

---@class ArbitrageSearchResult
---@field tiers ArbitrageSearchTier[] cheapest first
---@field listed number units listed in all, not counting your own
---@field requested number how many the search was for
---@field full boolean the server sent every listing, not just enough for requested
---@field at number when the search answered
---@field commodity boolean sold by quantity, rather than one auction at a time

---@class ArbitrageSearchQuote
---@field cost number copper to buy what's asked for, or as many as are listed, cheapest first
---@field listed number
---@field at number

---@class ArbitrageSearchRun
---@field total number
---@field done number searches answered or given up on
---@field finished boolean?
---@field stopped boolean? the Auction House closed before it finished
---@field onFinished fun()? called once every search has answered or given up, unless stopped

-- A search unanswered this long is sent again, once, then given up on.
local SEARCH_TIMEOUT_SECONDS = 2
local RETRIES = 1

local Print = ns.Print

local frame = CreateFrame("Frame")
---@type table<number, ArbitrageSearchResult>
local results = {}
---@type ArbitrageSearchRequest[]
local queue = {}
---@type ArbitrageSearchRequest?
local current
---@type ArbitrageSearchRun?
local run

-- The shopping list shows searches as they start, answer, and finish.
local function Changed()
  ns.ShoppingPanel.Refresh()
end

local function Finish()
  if run and not run.finished then
    run.finished = true
    if not run.stopped and run.onFinished then
      run.onFinished()
    end
  end
end

---@param itemID number
---@return string
local function ItemText(itemID)
  local name, link = C_Item.GetItemInfo(itemID)
  return link or name or ("item " .. itemID)
end

local SendNext

-- Sends a search the server doesn't answer again, then gives up on it, says so, and moves on.
---@param request ArbitrageSearchRequest
local function WaitFor(request)
  local token = {}
  request.token = token
  C_Timer.After(SEARCH_TIMEOUT_SECONDS, function()
    if not (current and current.token == token and run) then
      return
    end
    current = nil
    if (request.attempts or 0) <= RETRIES then
      table.insert(queue, 1, request)
    else
      run.done = run.done + 1
      Print("Couldn't refresh the price of " .. ItemText(request.itemID) .. ": the Auction House didn't answer.")
    end
    SendNext()
    Changed()
  end)
end

-- One search at a time, each sent once the Auction House is ready for it.
SendNext = function()
  if current or not run then
    return
  end
  local request = queue[1]
  if not request then
    Finish()
    return
  end
  if not C_AuctionHouse.IsThrottledMessageSystemReady() then
    return
  end
  table.remove(queue, 1)
  current = request
  request.attempts = (request.attempts or 0) + 1
  local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
  C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(request.itemID), sorts, false)
  WaitFor(request)
end

local function ByUnitPrice(left, right)
  return left.unitPrice < right.unitPrice
end

---@param tiers ArbitrageSearchTier[]
---@param listed number
---@param full boolean
---@param commodity boolean
local function Record(tiers, listed, full, commodity)
  local request = current
  if not request or not run then
    return
  end
  table.sort(tiers, ByUnitPrice)
  results[request.itemID] = {
    tiers = tiers,
    listed = listed,
    requested = request.quantity,
    full = full,
    at = time(),
    commodity = commodity,
  }
  current = nil
  run.done = run.done + 1
  SendNext()
  Changed()
end

---@param itemID number
local function ReadCommodities(itemID)
  local tiers, listed = {}, 0
  for index = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
    local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, index)
    local quantity = info and info.quantity - (info.numOwnerItems or 0) or 0
    if quantity > 0 then
      tiers[#tiers + 1] = { unitPrice = info.unitPrice, quantity = quantity }
      listed = listed + quantity
    end
  end
  local full = C_AuctionHouse.HasFullCommoditySearchResults(itemID)
  if listed < current.quantity and not full then
    C_AuctionHouse.RequestMoreCommoditySearchResults(itemID)
    WaitFor(current)
    return
  end
  Record(tiers, listed, full, true)
end

-- Anything that isn't a commodity lists rows of identical auctions, one item each: quantity is how
-- many, and the buyout is for one.
---@param itemKey table
local function ReadItems(itemKey)
  local tiers, listed = {}, 0
  for index = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) do
    local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, index)
    if info and info.buyoutAmount and info.quantity > 0 and not info.containsOwnerItem then
      tiers[#tiers + 1] = { unitPrice = info.buyoutAmount, quantity = info.quantity, auctionID = info.auctionID }
      listed = listed + info.quantity
    end
  end
  local full = C_AuctionHouse.HasFullItemSearchResults(itemKey)
  if listed < current.quantity and not full then
    C_AuctionHouse.RequestMoreItemSearchResults(itemKey)
    WaitFor(current)
    return
  end
  Record(tiers, listed, full, false)
end

-- Searches each material for its listings, replacing any earlier search of it. A search already
-- running finishes first.
---@param requests ArbitrageSearchRequest[]
---@param onFinished fun()? called once every search has answered or given up, unless the Auction House closes first
---@return boolean started
function ns.ShoppingSearch.Start(requests, onFinished)
  if ns.ShoppingSearch.IsRunning() or #requests == 0 then
    return false
  end
  queue = {}
  for index, request in ipairs(requests) do
    queue[index] = { itemID = request.itemID, quantity = request.quantity }
  end
  run = { total = #requests, done = 0, onFinished = onFinished }
  SendNext()
  Changed()
  return true
end

---@return boolean
function ns.ShoppingSearch.IsRunning()
  return run ~= nil and not run.finished
end

-- The latest run, finished or not, or nil before the first.
---@return ArbitrageSearchRun?
function ns.ShoppingSearch.GetRun()
  return run
end

-- What buying the quantity costs at the listings the latest search of the item found, or nil if it
-- hasn't been searched, or was searched for fewer and there may be listings it didn't fetch. When
-- fewer are listed, it's the cost of all of them.
---@param itemID number
---@param quantity number
---@return ArbitrageSearchQuote?
function ns.ShoppingSearch.Quote(itemID, quantity)
  local result = results[itemID]
  if not result or (not result.full and quantity > result.listed) then
    return nil
  end
  local remaining, cost = quantity, 0
  for _, tier in ipairs(result.tiers) do
    if remaining <= 0 then
      break
    end
    local taken = math.min(remaining, tier.quantity)
    cost = cost + taken * tier.unitPrice
    remaining = remaining - taken
  end
  return { cost = math.floor(cost + 0.5), listed = result.listed, at = result.at }
end

-- What one costs on average when buying as many as the latest search was for, or nil if it hasn't
-- been searched or none are listed.
---@param itemID number
---@return number?
function ns.ShoppingSearch.UnitPrice(itemID)
  local result = results[itemID]
  local quote = result and ns.ShoppingSearch.Quote(itemID, result.requested)
  if not quote or quote.listed == 0 then
    return nil
  end
  return quote.cost / math.min(result.requested, quote.listed)
end

-- Whether the item sells as a commodity, by quantity, rather than one auction at a time: as its
-- latest search found, or as the Auction House says. Nil while the Auction House is still loading
-- what it knows of the item, which ITEM_KEY_ITEM_INFO_RECEIVED follows.
---@param itemID number
---@return boolean?
function ns.ShoppingSearch.IsCommodity(itemID)
  local result = results[itemID]
  if result then
    return result.commodity
  end
  local info = C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.MakeItemKey(itemID))
  return info and info.isCommodity
end

-- The listings the latest search found of something that isn't a commodity, cheapest first, or nil
-- if it hasn't been searched or is a commodity.
---@param itemID number
---@return ArbitrageSearchTier[]?
function ns.ShoppingSearch.GetAuctions(itemID)
  local result = results[itemID]
  return result and not result.commodity and result.tiers or nil
end

-- Takes bought units off the item's listings, cheapest first, as buying does.
---@param itemID number
---@param quantity number
function ns.ShoppingSearch.Consume(itemID, quantity)
  local result = results[itemID]
  if not result then
    return
  end
  local remaining = quantity
  while remaining > 0 and result.tiers[1] do
    local tier = result.tiers[1]
    local taken = math.min(remaining, tier.quantity)
    tier.quantity = tier.quantity - taken
    remaining = remaining - taken
    if tier.quantity == 0 then
      table.remove(result.tiers, 1)
    end
  end
  result.listed = math.max(0, result.listed - quantity)
  Changed()
end

function ns.ShoppingSearch.Register()
  frame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
  frame:RegisterEvent("COMMODITY_SEARCH_RESULTS_ADDED")
  frame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
  frame:RegisterEvent("ITEM_SEARCH_RESULTS_ADDED")
  frame:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  frame:SetScript("OnEvent", function(_, eventName, ...)
    if eventName == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
      SendNext()
    elseif eventName == "AUCTION_HOUSE_CLOSED" then
      if ns.ShoppingSearch.IsRunning() then
        queue, current = {}, nil
        run.stopped = true
        Finish()
        Print("Stopped refreshing prices: the Auction House closed.")
        Changed()
      end
    elseif not current then
      return
    elseif eventName == "COMMODITY_SEARCH_RESULTS_UPDATED" or eventName == "COMMODITY_SEARCH_RESULTS_ADDED" then
      local itemID = ...
      if itemID == current.itemID then
        ReadCommodities(itemID)
      end
    else
      local itemKey = ...
      if type(itemKey) == "table" and itemKey.itemID == current.itemID then
        ReadItems(itemKey)
      end
    end
  end)
end

local _, ns = ...

ns.ShoppingPurchase = {}

-- Where buying is: idle; asking for a commodity's price, waiting on you to accept a higher one, or
-- buying it; finding the auctions of what isn't a commodity; or buying those auctions, one a click.
---@alias ArbitragePurchaseStep "idle"|"quoting"|"confirm"|"buying"|"reviewing"|"auctions"|"bidding"

---@class ArbitrageCommodityPurchase
---@field itemID number
---@field quantity number
---@field expected number? copper the list showed, which the purchase may cost without asking
---@field total number? what the Auction House quoted

-- One item. A row of identical auctions lists the next under a new ID once one is bought, so all but
-- the first of a row find theirs when it's their turn.
---@class ArbitragePlannedAuction
---@field itemID number
---@field auctionID number?
---@field buyout number

---@class ArbitrageAuctionPlan
---@field auctions ArbitragePlannedAuction[] in buying order
---@field index number the next to buy
---@field total number copper for every auction
---@field short table<number, number> units not listed, by item

-- How long the Auction House has to answer a purchase before buying gives up on it.
local ANSWER_TIMEOUT_SECONDS = 10

local frame = CreateFrame("Frame")
---@type ArbitragePurchaseStep
local step = "idle"
---@type ArbitrageCommodityPurchase?
local purchase
---@type ArbitrageAuctionPlan?
local plan
-- Marks what a timer was started for, so one from an earlier step does nothing.
local token

local Print = ns.Print
local Coins = C_CurrencyInfo.GetCoinTextureString

---@param itemID number
---@param quantity number
---@return string
local function Describe(itemID, quantity)
  local name, link = C_Item.GetItemInfo(itemID)
  return quantity .. "x " .. (link or name or ("item " .. itemID))
end

---@param itemID number
---@param quantity number
---@param reason string
local function Fail(itemID, quantity, reason)
  Print("Couldn't buy " .. Describe(itemID, quantity) .. ": " .. reason)
end

-- The shopping list shows buying as it moves from step to step.
local function Changed()
  ns.ShoppingPanel.Refresh()
end

---@return ArbitragePurchaseStep step, ArbitrageCommodityPurchase? purchase, ArbitrageAuctionPlan? plan
function ns.ShoppingPurchase.GetStep()
  return step, purchase, plan
end

-- Back to idle. The auction plan stays while there are auctions left to buy.
local function Reset()
  step = plan and "auctions" or "idle"
  purchase = nil
  token = nil
  Changed()
end

local function Stop()
  plan = nil
  Reset()
end

-- Moves to a step that waits on the Auction House, and gives up if it doesn't answer.
---@param waiting ArbitragePurchaseStep
---@param seconds number?
---@param onTimeout fun()
local function Await(waiting, seconds, onTimeout)
  step = waiting
  local mine = {}
  token = mine
  C_Timer.After(seconds or ANSWER_TIMEOUT_SECONDS, function()
    if token == mine and step == waiting then
      onTimeout()
    end
  end)
end

local function NoAnswer()
  if purchase then
    Fail(purchase.itemID, purchase.quantity, "the Auction House didn't answer.")
    C_AuctionHouse.CancelCommoditiesPurchase()
  end
  Stop()
end

-- Asks the Auction House what buying the quantity costs right now. Within what the list showed, it
-- buys at once; costing more, it waits for ConfirmAnyway. Needs a click.
---@param itemID number
---@param quantity number
---@param expected number?
---@return boolean started
function ns.ShoppingPurchase.BuyCommodity(itemID, quantity, expected)
  if step ~= "idle" then
    return false
  end
  purchase = { itemID = itemID, quantity = quantity, expected = expected }
  C_AuctionHouse.StartCommoditiesPurchase(itemID, quantity)
  Await("quoting", nil, NoAnswer)
  Changed()
  return true
end

---@param totalPrice number
local function OnPriceUpdated(totalPrice)
  if step ~= "quoting" or not purchase then
    return
  end
  purchase.total = totalPrice
  if totalPrice > GetMoney() then
    Print("Not enough gold for " .. Describe(purchase.itemID, purchase.quantity) .. " (" .. Coins(totalPrice) .. ").")
    C_AuctionHouse.CancelCommoditiesPurchase()
    Reset()
    return
  end
  if purchase.expected and totalPrice <= purchase.expected then
    C_AuctionHouse.ConfirmCommoditiesPurchase(purchase.itemID, purchase.quantity)
    Await("buying", nil, NoAnswer)
  else
    -- The quote holds only so long, after which it has to be asked for again.
    Await("confirm", math.max(1, C_AuctionHouse.GetQuoteDurationRemaining()), function()
      C_AuctionHouse.CancelCommoditiesPurchase()
      Reset()
    end)
  end
  Changed()
end

-- Buys at the higher price the Auction House quoted. Needs a click.
function ns.ShoppingPurchase.ConfirmAnyway()
  if step ~= "confirm" or not purchase then
    return
  end
  C_AuctionHouse.ConfirmCommoditiesPurchase(purchase.itemID, purchase.quantity)
  Await("buying", nil, NoAnswer)
  Changed()
end

-- Drops a commodity purchase waiting on a price or on you, or stops buying auctions.
function ns.ShoppingPurchase.Cancel()
  if step == "quoting" or step == "confirm" then
    C_AuctionHouse.CancelCommoditiesPurchase()
    Reset()
  elseif step == "auctions" then
    Stop()
  end
end

-- The cheapest auctions, one item each, until each material's need is covered.
---@param requests ArbitrageSearchRequest[]
---@return ArbitrageAuctionPlan
local function PlanAuctions(requests)
  ---@type ArbitrageAuctionPlan
  local newPlan = { auctions = {}, index = 1, total = 0, short = {} }
  for _, request in ipairs(requests) do
    local remaining = request.quantity
    for _, row in ipairs(ns.ShoppingSearch.GetAuctions(request.itemID) or {}) do
      local taken = math.min(remaining, row.quantity)
      for count = 1, taken do
        newPlan.auctions[#newPlan.auctions + 1] = {
          itemID = request.itemID,
          auctionID = count == 1 and row.auctionID or nil,
          buyout = row.unitPrice,
        }
      end
      newPlan.total = newPlan.total + taken * row.unitPrice
      remaining = remaining - taken
    end
    if remaining > 0 then
      newPlan.short[request.itemID] = remaining
    end
  end
  return newPlan
end

-- An auction the Auction House lists of the item at the planned price, other than the one before it,
-- just bought from the same row, which the Auction House may list a moment longer.
---@param auction ArbitragePlannedAuction
---@return number?
local function FindListed(auction)
  local itemKey = C_AuctionHouse.MakeItemKey(auction.itemID)
  local bought = plan.auctions[plan.index - 1].auctionID
  for index = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) do
    local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, index)
    if info and info.buyoutAmount == auction.buyout and not info.containsOwnerItem and info.auctionID ~= bought then
      return info.auctionID
    end
  end
end

-- Searches what isn't sold as a commodity for its auctions, then hands the auctions to buy to
-- onPlanned, for you to accept before any is bought.
---@param requests ArbitrageSearchRequest[]
---@param onPlanned fun(plan: ArbitrageAuctionPlan)
---@return boolean started
function ns.ShoppingPurchase.Review(requests, onPlanned)
  if step ~= "idle" then
    return false
  end
  local started = ns.ShoppingSearch.Start(requests, function()
    step = "idle"
    onPlanned(PlanAuctions(requests))
    Changed()
  end)
  if started then
    step = "reviewing"
    Changed()
  end
  return started
end

-- Buys the next auction of the plan. Needs a click.
function ns.ShoppingPurchase.BuyNextAuction()
  if step ~= "auctions" or not plan then
    return
  end
  local auction = plan.auctions[plan.index]
  if not auction then
    Stop()
    return
  end
  if auction.buyout > GetMoney() then
    Print("Not enough gold for " .. Describe(auction.itemID, 1) .. " (" .. Coins(auction.buyout) .. ").")
    Stop()
    return
  end
  auction.auctionID = auction.auctionID or FindListed(auction)
  if not auction.auctionID then
    Fail(
      auction.itemID,
      1,
      "none are listed at " .. Coins(auction.buyout) .. " any more. Review the auctions to pick again."
    )
    Stop()
    return
  end
  C_AuctionHouse.PlaceBid(auction.auctionID, auction.buyout)
  Await("bidding", nil, function()
    Fail(auction.itemID, 1, "the Auction House didn't answer.")
    Stop()
  end)
  Changed()
end

-- Accepts a plan and buys its first auction, from the click that accepted it.
---@param accepted ArbitrageAuctionPlan
function ns.ShoppingPurchase.StartAuctions(accepted)
  if step ~= "idle" or #accepted.auctions == 0 then
    return
  end
  plan = accepted
  step = "auctions"
  ns.ShoppingPurchase.BuyNextAuction()
end

local ERROR_REASONS = {
  [0] = "not enough gold",
  [4] = "it's no longer listed",
  [25] = "it's no longer listed",
}

---@param errorCode number?
local function OnError(errorCode)
  local reason = ERROR_REASONS[errorCode or -1] or "the Auction House refused it"
  if step == "bidding" and plan then
    local auction = plan.auctions[plan.index]
    Fail(auction.itemID, 1, reason .. ". Review the auctions to pick again.")
    Stop()
  elseif (step == "quoting" or step == "buying") and purchase then
    Fail(purchase.itemID, purchase.quantity, reason .. ".")
    Reset()
  end
end

function ns.ShoppingPurchase.Register()
  frame:RegisterEvent("COMMODITY_PRICE_UPDATED")
  frame:RegisterEvent("COMMODITY_PRICE_UNAVAILABLE")
  frame:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
  frame:RegisterEvent("COMMODITY_PURCHASE_FAILED")
  frame:RegisterEvent("AUCTION_HOUSE_PURCHASE_COMPLETED")
  frame:RegisterEvent("AUCTION_HOUSE_SHOW_ERROR")
  frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  frame:SetScript("OnEvent", function(_, eventName, ...)
    if eventName == "COMMODITY_PRICE_UPDATED" then
      local _, totalPrice = ...
      OnPriceUpdated(totalPrice)
    elseif eventName == "COMMODITY_PRICE_UNAVAILABLE" then
      if purchase and (step == "quoting" or step == "confirm" or step == "buying") then
        Fail(purchase.itemID, purchase.quantity, "not enough are listed any more.")
        Reset()
      end
    elseif eventName == "COMMODITY_PURCHASE_SUCCEEDED" then
      if step == "buying" and purchase then
        PlaySound(SOUNDKIT.LOOT_WINDOW_COIN_SOUND)
        ns.ShoppingSearch.Consume(purchase.itemID, purchase.quantity)
        -- It arrives by mail, where the list counts it until you collect it.
        ns.ShoppingList.RecordPurchase(purchase.itemID, purchase.quantity)
        Reset()
      end
    elseif eventName == "COMMODITY_PURCHASE_FAILED" then
      OnError(nil)
    elseif eventName == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
      local auctionID = ...
      local auction = plan and plan.auctions[plan.index]
      if step == "bidding" and plan and auction and auction.auctionID == auctionID then
        PlaySound(SOUNDKIT.LOOT_WINDOW_COIN_SOUND)
        ns.ShoppingSearch.Consume(auction.itemID, 1)
        ns.ShoppingList.RecordPurchase(auction.itemID, 1)
        plan.index = plan.index + 1
        if not plan.auctions[plan.index] then
          plan = nil
        end
        Reset()
      end
    elseif eventName == "AUCTION_HOUSE_SHOW_ERROR" then
      OnError(...)
    elseif eventName == "AUCTION_HOUSE_CLOSED" then
      if step == "quoting" or step == "confirm" then
        C_AuctionHouse.CancelCommoditiesPurchase()
      end
      if step ~= "idle" then
        Stop()
      end
    end
  end)
end

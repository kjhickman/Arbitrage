local NewEnvironment = dofile("tests/support/Environment.lua")

describe("ShoppingPurchase", function()
  local environment
  local ns, onEvent, delayed, calls, chat, sounds, money, consumed, auctions, searchStarts, changes, mailed

  local COPPER_ORE, BANDAGE_KIT, ODD_REAGENT = 30, 60, 61

  local function Fire(eventName, ...)
    onEvent(nil, eventName, ...)
  end

  -- Runs the timers waiting this long.
  local function RunDelayed(seconds)
    local remaining = {}
    local due = {}
    for _, timer in ipairs(delayed) do
      if timer.seconds == seconds then
        due[#due + 1] = timer.callback
      else
        remaining[#remaining + 1] = timer
      end
    end
    delayed = remaining
    for _, callback in ipairs(due) do
      callback()
    end
  end

  local function Step()
    return (ns.ShoppingPurchase.GetStep())
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    delayed, calls, chat, sounds, consumed, auctions, searchStarts, mailed = {}, {}, {}, {}, {}, {}, {}, {}
    money, changes = 100000, 0

    function CreateFrame()
      return {
        RegisterEvent = function() end,
        SetScript = function(_, _, callback)
          onEvent = callback
        end,
      }
    end
    C_Timer = {
      After = function(seconds, callback)
        delayed[#delayed + 1] = { seconds = seconds, callback = callback }
      end,
    }
    function print(message)
      chat[#chat + 1] = message
    end
    function GetMoney()
      return money
    end
    function PlaySound(sound)
      sounds[#sounds + 1] = sound
    end
    SOUNDKIT = { LOOT_WINDOW_COIN_SOUND = 120 }
    C_Item = {
      GetItemInfo = function(itemID)
        if itemID == COPPER_ORE then
          return "Copper Ore", "[Copper Ore]"
        end
      end,
    }
    C_CurrencyInfo = {
      GetCoinTextureString = function(copper)
        return copper .. "c"
      end,
    }
    C_AuctionHouse = {
      StartCommoditiesPurchase = function(itemID, quantity)
        calls[#calls + 1] = { "start", itemID, quantity }
      end,
      ConfirmCommoditiesPurchase = function(itemID, quantity)
        calls[#calls + 1] = { "confirm", itemID, quantity }
      end,
      CancelCommoditiesPurchase = function()
        calls[#calls + 1] = { "cancel" }
      end,
      GetQuoteDurationRemaining = function()
        return 25
      end,
      PlaceBid = function(auctionID, bid)
        calls[#calls + 1] = { "bid", auctionID, bid }
      end,
    }
    ns = {
      ShoppingList = {
        RecordPurchase = function(itemID, quantity)
          mailed[#mailed + 1] = { itemID, quantity }
        end,
      },
      ShoppingSearch = {
        Consume = function(itemID, quantity, auctionID)
          consumed[#consumed + 1] = { itemID, quantity, auctionID }
        end,
        Start = function(requests, onFinished)
          searchStarts[#searchStarts + 1] = { requests = requests, onFinished = onFinished }
          return true
        end,
        GetAuctions = function(itemID)
          return auctions[itemID]
        end,
      },
    }
    assert(loadfile("src/ShoppingPurchase.lua"), "loads ShoppingPurchase.lua")("Arbitrage", ns)
    ns.ShoppingPurchase.Register()
    ns.ShoppingPurchase.OnChange(function()
      changes = changes + 1
    end)
  end)

  describe("a commodity", function()
    it("buys at once when the quote costs no more than the list showed", function()
      setfenv(1, environment)
      assert.is_true(ns.ShoppingPurchase.BuyCommodity(COPPER_ORE, 8, 210))
      assert.are.same({ { "start", COPPER_ORE, 8 } }, calls)
      assert.are.equal("quoting", Step())
      assert.is_false(ns.ShoppingPurchase.BuyCommodity(COPPER_ORE, 8, 210), "buys one thing at a time")

      Fire("COMMODITY_PRICE_UPDATED", 26, 210)
      assert.are.same({ "confirm", COPPER_ORE, 8 }, calls[2])
      assert.are.equal("buying", Step())

      Fire("COMMODITY_PURCHASE_SUCCEEDED")
      assert.are.equal("idle", Step())
      assert.are.same({ 120 }, sounds)
      assert.are.same({ { COPPER_ORE, 8 } }, consumed)
      assert.are.same({ { COPPER_ORE, 8 } }, mailed, "counts what's on its way by mail")
      assert.are.same({}, chat)
      -- Asking, the quote, and the purchase.
      assert.are.equal(3, changes)
    end)

    it("waits for you to accept a higher price, until the quote runs out", function()
      setfenv(1, environment)
      ns.ShoppingPurchase.BuyCommodity(COPPER_ORE, 8, 210)
      Fire("COMMODITY_PRICE_UPDATED", 27, 214)
      local step, purchase = ns.ShoppingPurchase.GetStep()
      assert.are.equal("confirm", step)
      assert.are.same({ itemID = COPPER_ORE, quantity = 8, expected = 210, total = 214 }, purchase)
      assert.are.equal(1, #calls, "doesn't buy without asking")

      ns.ShoppingPurchase.ConfirmAnyway()
      assert.are.same({ "confirm", COPPER_ORE, 8 }, calls[2])
      assert.are.equal("buying", Step())

      -- Without a price from the list, any quote asks first.
      Fire("COMMODITY_PURCHASE_SUCCEEDED")
      ns.ShoppingPurchase.BuyCommodity(COPPER_ORE, 2, nil)
      Fire("COMMODITY_PRICE_UPDATED", 20, 40)
      assert.are.equal("confirm", Step())
      RunDelayed(25)
      assert.are.equal("idle", Step(), "lets the quote go when it expires")
      assert.are.same({ "cancel" }, calls[#calls])
    end)

    it("won't buy what you can't afford", function()
      setfenv(1, environment)
      money = 200
      ns.ShoppingPurchase.BuyCommodity(COPPER_ORE, 8, 210)
      Fire("COMMODITY_PRICE_UPDATED", 26, 210)
      assert.are.equal("idle", Step())
      assert.are.same({ "cancel" }, calls[2])
      assert.are.same({ "|cff00ccffArbitrage:|r Not enough gold for 8x [Copper Ore] (210c)." }, chat)
    end)

    it("says in chat when the listings are gone, the purchase fails, or the Auction House is silent", function()
      setfenv(1, environment)
      ns.ShoppingPurchase.BuyCommodity(COPPER_ORE, 8, 210)
      Fire("COMMODITY_PRICE_UNAVAILABLE")
      assert.are.equal("idle", Step())

      ns.ShoppingPurchase.BuyCommodity(COPPER_ORE, 8, 210)
      Fire("COMMODITY_PRICE_UPDATED", 26, 210)
      Fire("COMMODITY_PURCHASE_FAILED")
      assert.are.equal("idle", Step())
      assert.are.same({}, consumed)
      assert.are.same({}, mailed)

      ns.ShoppingPurchase.BuyCommodity(COPPER_ORE, 8, 210)
      RunDelayed(10)
      assert.are.equal("idle", Step())
      assert.are.same({ "cancel" }, calls[#calls])
      assert.are.same({
        "|cff00ccffArbitrage:|r Couldn't buy 8x [Copper Ore]: not enough are listed any more.",
        "|cff00ccffArbitrage:|r Couldn't buy 8x [Copper Ore]: the Auction House refused it.",
        "|cff00ccffArbitrage:|r Couldn't buy 8x [Copper Ore]: the Auction House didn't answer.",
      }, chat)
      -- The earlier purchases' timers find nothing to give up on.
      RunDelayed(10)
      assert.are.equal(3, #chat)
    end)

    it("lets go of a purchase you cancel or leave the Auction House on", function()
      setfenv(1, environment)
      ns.ShoppingPurchase.BuyCommodity(COPPER_ORE, 8, 210)
      Fire("COMMODITY_PRICE_UPDATED", 27, 214)
      ns.ShoppingPurchase.Cancel()
      assert.are.equal("idle", Step())
      assert.are.same({ "cancel" }, calls[#calls])

      ns.ShoppingPurchase.BuyCommodity(COPPER_ORE, 8, 210)
      Fire("AUCTION_HOUSE_CLOSED")
      assert.are.equal("idle", Step())
      assert.are.same({ "cancel" }, calls[#calls])
      Fire("COMMODITY_PRICE_UPDATED", 26, 210)
      assert.are.equal("idle", Step(), "ignores a quote for a purchase it let go")
    end)
  end)

  describe("auctions", function()
    -- Bandage Kits come two to an auction; one Odd Reagent auction holds three.
    before_each(function()
      setfenv(1, environment)
      auctions[BANDAGE_KIT] = {
        { auctionID = 1, quantity = 2, buyout = 100, unitPrice = 50 },
        { auctionID = 2, quantity = 2, buyout = 120, unitPrice = 60 },
        { auctionID = 3, quantity = 2, buyout = 140, unitPrice = 70 },
      }
      auctions[ODD_REAGENT] = { { auctionID = 4, quantity = 3, buyout = 90, unitPrice = 30 } }
    end)

    local function ReviewAndAccept(requests)
      local planned
      assert.is_true(ns.ShoppingPurchase.Review(requests, function(plan)
        planned = plan
      end))
      assert.are.equal("reviewing", Step())
      searchStarts[#searchStarts].onFinished()
      assert.are.equal("idle", Step())
      return planned
    end

    it("finds the cheapest whole auctions for each need, saying what's extra and what isn't listed", function()
      setfenv(1, environment)
      local requests = {
        { itemID = BANDAGE_KIT, quantity = 3 },
        { itemID = ODD_REAGENT, quantity = 5 },
      }
      local plan = ReviewAndAccept(requests)
      assert.are.equal(requests, searchStarts[1].requests, "searches them first")
      assert.are.same({
        auctions = {
          { itemID = BANDAGE_KIT, auctionID = 1, quantity = 2, buyout = 100 },
          { itemID = BANDAGE_KIT, auctionID = 2, quantity = 2, buyout = 120 },
          { itemID = ODD_REAGENT, auctionID = 4, quantity = 3, buyout = 90 },
        },
        index = 1,
        total = 310,
        extra = { [BANDAGE_KIT] = 1 },
        short = { [ODD_REAGENT] = 2 },
      }, plan)
      assert.are.same({}, calls, "buys nothing until accepted")
    end)

    it("buys one auction a click once accepted, starting from the click that accepted", function()
      setfenv(1, environment)
      local plan = ReviewAndAccept({ { itemID = BANDAGE_KIT, quantity = 3 } })
      ns.ShoppingPurchase.StartAuctions(plan)
      assert.are.same({ { "bid", 1, 100 } }, calls)
      assert.are.equal("bidding", Step())

      Fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 99)
      assert.are.equal("bidding", Step(), "waits for its own auction")
      Fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 1)
      local step, _, current = ns.ShoppingPurchase.GetStep()
      assert.are.same({ "auctions", 2 }, { step, current.index })
      assert.are.same({ { BANDAGE_KIT, 2, 1 } }, consumed)
      assert.are.same({ { BANDAGE_KIT, 2 } }, mailed)
      assert.are.same({ 120 }, sounds)

      ns.ShoppingPurchase.BuyNextAuction()
      assert.are.same({ "bid", 2, 120 }, calls[2])
      Fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 2)
      assert.are.same({ "idle" }, { ns.ShoppingPurchase.GetStep() }, "finishes after the last")
    end)

    it("stops when an auction is gone, can't be afforded, or you stop it", function()
      setfenv(1, environment)
      local requests = { { itemID = BANDAGE_KIT, quantity = 3 } }
      ns.ShoppingPurchase.StartAuctions(ReviewAndAccept(requests))
      Fire("AUCTION_HOUSE_SHOW_ERROR", 4)
      assert.are.same({ "idle" }, { ns.ShoppingPurchase.GetStep() })
      assert.are.equal(
        "|cff00ccffArbitrage:|r Couldn't buy 2x item 60: it's no longer listed. Review the auctions to pick again.",
        chat[1]
      )

      money = 110
      ns.ShoppingPurchase.StartAuctions(ReviewAndAccept(requests))
      Fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 1)
      ns.ShoppingPurchase.BuyNextAuction()
      assert.are.equal("idle", Step())
      assert.are.equal("|cff00ccffArbitrage:|r Not enough gold for 2x item 60 (120c).", chat[2])

      money = 100000
      ns.ShoppingPurchase.StartAuctions(ReviewAndAccept(requests))
      Fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 1)
      ns.ShoppingPurchase.Cancel()
      assert.are.same({ "idle" }, { ns.ShoppingPurchase.GetStep() })
    end)
  end)
end)

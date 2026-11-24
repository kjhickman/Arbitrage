local NewEnvironment = dofile("tests/support/Environment.lua")

describe("ShoppingList", function()
  local environment
  local ns, realmName, recipes, choices, choiceRequests, buyouts, vendorPrices, owned, names, changes, scanPlans
  local refreshedChoices

  -- Item IDs: an Anvil uses two Copper Bars and a Coarse Stone; a Copper Bar is smelted from a
  -- Copper Ore, and a Bronze Bar from a Copper Bar and a Tin Ore, two at a time.
  local ANVIL, BRONZE_TOOL, COPPER_BAR, BRONZE_BAR, COARSE_STONE, COPPER_ORE, TIN_ORE, FLUX =
    1, 2, 10, 11, 20, 30, 31, 40

  local function Opportunity(itemID, recipeKey, withBuyouts)
    return { itemID = itemID, recipeKey = recipeKey, buyoutMaterials = withBuyouts ~= false and {} or nil }
  end

  -- Each material row as "name depth need have kind crafts-or-toBuy cost".
  local function Describe(materials)
    local lines = {}
    for index, row in ipairs(materials.rows) do
      local amount = row.kind == "make" and row.crafts or row.toBuy
      lines[index] = table.concat({
        row.name,
        row.depth,
        row.need,
        row.have,
        row.kind,
        amount,
        tostring(row.cost),
      }, " ")
    end
    return lines
  end

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    realmName = "Test Realm"
    names = {
      [COPPER_BAR] = "Copper Bar",
      [BRONZE_BAR] = "Bronze Bar",
      [COARSE_STONE] = "Coarse Stone",
      [COPPER_ORE] = "Copper Ore",
      [TIN_ORE] = "Tin Ore",
      [FLUX] = "Flux",
    }
    recipes = {
      [ANVIL] = {
        {
          recipeKey = "anvil",
          outputItemID = ANVIL,
          outputQuantity = 1,
          reagents = {
            { itemID = COPPER_BAR, quantity = 2, name = "Copper Bar" },
            { itemID = COARSE_STONE, quantity = 1, name = "Coarse Stone" },
          },
        },
      },
      [BRONZE_TOOL] = {
        {
          recipeKey = "bronze-tool",
          outputItemID = BRONZE_TOOL,
          outputQuantity = 1,
          reagents = {
            { itemID = BRONZE_BAR, quantity = 3, name = "Bronze Bar" },
            { itemID = FLUX, quantity = 1, name = "Flux" },
          },
        },
      },
      [COPPER_BAR] = {
        {
          recipeKey = "smelt-copper",
          outputItemID = COPPER_BAR,
          outputQuantity = 1,
          reagents = { { itemID = COPPER_ORE, quantity = 1, name = "Copper Ore" } },
        },
      },
      [BRONZE_BAR] = {
        {
          recipeKey = "smelt-bronze",
          outputItemID = BRONZE_BAR,
          outputQuantity = 2,
          reagents = {
            { itemID = COPPER_BAR, quantity = 1, name = "Copper Bar" },
            { itemID = TIN_ORE, quantity = 1, name = "Tin Ore" },
          },
        },
      },
    }
    choices = {
      [ANVIL] = { [COPPER_BAR] = "smelt-copper" },
      [BRONZE_TOOL] = { [BRONZE_BAR] = "smelt-bronze", [COPPER_BAR] = "smelt-copper" },
    }
    choiceRequests = {}
    refreshedChoices = {}
    -- The cheapest way to make one of each material at Buyout prices.
    scanPlans = {
      [COPPER_BAR] = { recipeKey = "smelt-copper", cost = 25 },
      [BRONZE_BAR] = { recipeKey = "smelt-bronze", cost = 27.5 },
    }
    buyouts = { [COPPER_ORE] = 25, [TIN_ORE] = 30, [COARSE_STONE] = 10, [COPPER_BAR] = 60, [BRONZE_BAR] = 90 }
    vendorPrices = {}
    owned = {}
    changes = 0

    C_Item = {
      GetItemInfo = function(itemID)
        return names[itemID]
      end,
      GetItemCount = function(itemID, includeBank, includeUses, includeReagentBank, includeAccountBank)
        assert(includeBank and not includeUses and includeReagentBank and includeAccountBank, "counts every bank")
        return owned[itemID] or 0
      end,
    }
    ns = {
      Realm = {
        GetName = function()
          return realmName
        end,
      },
      RecipeBook = {
        GetRecipes = function(itemID)
          return recipes[itemID] or {}
        end,
      },
      Crafting = {
        -- With refreshed prices, the choices those prices make cheapest.
        GetChoices = function(itemID, recipeKey, atBuyout, unitPrice)
          choiceRequests[#choiceRequests + 1] = { itemID, recipeKey, atBuyout, unitPrice }
          if unitPrice then
            return refreshedChoices[itemID]
          end
          return choices[itemID]
        end,
        GetScanCostForItemID = function(itemID, recipeKeys)
          local plan = scanPlans[itemID]
          if plan and recipeKeys and not recipeKeys[plan.recipeKey] then
            return { isUnknown = true }
          end
          return plan
        end,
        GetBuyoutPurchasePrice = function(itemID)
          if vendorPrices[itemID] then
            return { value = vendorPrices[itemID], source = "vendor" }
          end
          return buyouts[itemID] and { value = buyouts[itemID], source = "auction" } or nil
        end,
      },
    }
    ARBITRAGE_SHOPPING = nil
    assert(loadfile("src/ShoppingList.lua"), "loads ShoppingList.lua")("Arbitrage", ns)
    ns.ShoppingList.Init()
    ns.ShoppingList.OnChange(function()
      changes = changes + 1
    end)
  end)

  it("keeps a list for each realm in its saved variable", function()
    setfenv(1, environment)
    assert.are.equal(1, ARBITRAGE_SHOPPING.__version)
    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 2)
    assert.are.same({ { itemID = ANVIL, recipeKey = "anvil", count = 2 } }, ARBITRAGE_SHOPPING["Test Realm"].crafts)

    realmName = "Other Realm"
    ns.ShoppingList.Init()
    assert.are.equal(0, ns.ShoppingList.GetCraftCount())

    realmName = "Test Realm"
    ns.ShoppingList.Init()
    assert.are.equal(2, ns.ShoppingList.GetCount(ANVIL))
  end)

  it("starts over when its saved list is another version, and drops crafts it can't read", function()
    setfenv(1, environment)
    ARBITRAGE_SHOPPING = {
      __version = 1,
      ["Test Realm"] = {
        crafts = {
          { itemID = ANVIL, recipeKey = "anvil", count = 2 },
          { itemID = COPPER_BAR, recipeKey = "smelt-copper", count = 0 },
          { itemID = "1", recipeKey = "anvil", count = 1 },
          "not a craft",
        },
        choices = {},
      },
    }
    ns.ShoppingList.Init()
    assert.are.same({ { itemID = ANVIL, recipeKey = "anvil", count = 2 } }, ns.ShoppingList.GetCrafts())

    ARBITRAGE_SHOPPING.__version = 0
    ns.ShoppingList.Init()
    assert.are.same({ __version = 1, ["Test Realm"] = { crafts = {}, choices = {} } }, ARBITRAGE_SHOPPING)
  end)

  it("adds crafts, adds more to a craft already listed, and caps how many", function()
    setfenv(1, environment)
    assert.is_true(ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 3))
    assert.is_true(ns.ShoppingList.Add(Opportunity(ANVIL, "anvil", false), 2))
    assert.are.equal(5, ns.ShoppingList.GetCount(ANVIL))
    assert.are.equal(1, ns.ShoppingList.GetCraftCount())
    assert.are.equal(2, changes)
    -- The choices follow the materials the details listed: at Buyout prices when it had them.
    assert.are.same({ { ANVIL, "anvil", true }, { ANVIL, "anvil", false } }, choiceRequests)

    assert.is_false(ns.ShoppingList.Add(Opportunity(BRONZE_TOOL, nil), 1))
    assert.is_false(ns.ShoppingList.Add(Opportunity(BRONZE_TOOL, "bronze-tool"), 0))
    assert.are.equal(0, ns.ShoppingList.GetCount(BRONZE_TOOL))
    assert.are.equal(2, changes)

    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 998)
    assert.are.equal(999, ns.ShoppingList.GetCount(ANVIL))
  end)

  it("keeps the list's choice for a material another craft already uses", function()
    setfenv(1, environment)
    choices[ANVIL] = { [COPPER_BAR] = false }
    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 1)
    ns.ShoppingList.Add(Opportunity(BRONZE_TOOL, "bronze-tool"), 1)

    -- The Anvil buys Copper Bars, so the Bronze Bars use bought ones too.
    assert.are.same({
      "Bronze Bar 0 3 0 make 2 nil",
      "Copper Bar 1 4 0 buy 4 240",
      "Tin Ore 1 2 0 buy 2 60",
      "Coarse Stone 0 1 0 buy 1 10",
      "Flux 0 1 0 buy 1 nil",
    }, Describe(ns.ShoppingList.GetMaterials()))
  end)

  it("changes counts, removes crafts with the choices only they used, and clears", function()
    setfenv(1, environment)
    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 1)
    ns.ShoppingList.Add(Opportunity(BRONZE_TOOL, "bronze-tool"), 1)

    ns.ShoppingList.SetCount(ANVIL, 4.5)
    assert.are.equal(4, ns.ShoppingList.GetCount(ANVIL))
    ns.ShoppingList.SetCount(ANVIL, 5000)
    assert.are.equal(999, ns.ShoppingList.GetCount(ANVIL))
    assert.are.equal(4, changes)

    ns.ShoppingList.Remove(BRONZE_TOOL)
    assert.are.equal(1, ns.ShoppingList.GetCraftCount())
    assert.are.same({ [COPPER_BAR] = "smelt-copper" }, ARBITRAGE_SHOPPING["Test Realm"].choices)

    ns.ShoppingList.SetCount(ANVIL, 0)
    assert.are.equal(0, ns.ShoppingList.GetCraftCount())
    assert.are.same({}, ARBITRAGE_SHOPPING["Test Realm"].choices)

    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 1)
    ns.ShoppingList.Clear()
    assert.are.same({ crafts = {}, choices = {} }, ARBITRAGE_SHOPPING["Test Realm"])
    assert.are.equal(8, changes)
  end)

  it("makes whole crafts of what you don't already have, and buys the rest", function()
    setfenv(1, environment)
    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 3)
    owned[COPPER_BAR] = 2
    owned[COPPER_ORE] = 1
    owned[COARSE_STONE] = 5

    local materials = ns.ShoppingList.GetMaterials()
    -- Six bars, two owned, so four are smelted from ore, one of which you have.
    assert.are.same({
      "Coarse Stone 0 3 5 buy 0 0",
      "Copper Bar 0 6 2 make 4 nil",
      "Copper Ore 1 4 1 buy 3 75",
    }, Describe(materials))
    assert.are.equal(75, materials.cost)
    assert.are.equal(0, materials.unpricedCount)

    -- Bronze Bars come two at a time, so three take two crafts.
    ns.ShoppingList.Clear()
    owned = {}
    ns.ShoppingList.Add(Opportunity(BRONZE_TOOL, "bronze-tool"), 1)
    assert.are.same({
      "Bronze Bar 0 3 0 make 2 nil",
      "Copper Bar 1 2 0 make 2 nil",
      "Copper Ore 2 2 0 buy 2 50",
      "Tin Ore 1 2 0 buy 2 60",
      "Flux 0 1 0 buy 1 nil",
    }, Describe(ns.ShoppingList.GetMaterials()))
  end)

  it("lists a material once with every craft's need, and leaves out what nothing needs any more", function()
    setfenv(1, environment)
    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 1)
    ns.ShoppingList.Add(Opportunity(BRONZE_TOOL, "bronze-tool"), 1)
    assert.are.same({
      "Bronze Bar 0 3 0 make 2 nil",
      "Copper Bar 1 4 0 make 4 nil",
      "Copper Ore 2 4 0 buy 4 100",
      "Tin Ore 1 2 0 buy 2 60",
      "Coarse Stone 0 1 0 buy 1 10",
      "Flux 0 1 0 buy 1 nil",
    }, Describe(ns.ShoppingList.GetMaterials()))

    -- With every bar in the bags, nothing is smelted, so no ore is needed.
    owned[COPPER_BAR] = 4
    owned[BRONZE_BAR] = 3
    assert.are.same({
      "Bronze Bar 0 3 3 make 0 nil",
      "Coarse Stone 0 1 0 buy 1 10",
      "Copper Bar 0 2 4 make 0 nil",
      "Flux 0 1 0 buy 1 nil",
    }, Describe(ns.ShoppingList.GetMaterials()))
  end)

  it("prices materials at the vendor when cheaper, and counts those without a price", function()
    setfenv(1, environment)
    ns.ShoppingList.Add(Opportunity(BRONZE_TOOL, "bronze-tool"), 2)
    vendorPrices[TIN_ORE] = 5
    local materials = ns.ShoppingList.GetMaterials()
    local tin = materials.rows[4]
    assert.are.same({ "Tin Ore", "vendor", 5, 15 }, { tin.name, tin.source, tin.unitPrice, tin.cost })
    -- Six Bronze Bars: three crafts, each with a Copper Bar from one ore and a Tin Ore.
    assert.are.equal(3 * 25 + 3 * 5, materials.cost)
    assert.are.equal(1, materials.unpricedCount, "Flux has no price")

    owned[FLUX] = 2
    assert.are.equal(0, ns.ShoppingList.GetMaterials().unpricedCount, "a material already owned needs no price")
  end)

  it("costs what a refresh found listed for materials bought at the Auction House", function()
    setfenv(1, environment)
    ns.ShoppingList.Add(Opportunity(BRONZE_TOOL, "bronze-tool"), 2)
    owned[TIN_ORE] = 1
    vendorPrices[FLUX] = 7
    local asked = {}
    -- Copper Ore has 3 cheaper listings and 10 dearer ones; only 1 Tin Ore is listed.
    local quotes = {
      [COPPER_ORE] = { cost = 3 * 20 + 26, listed = 13, at = 4000 },
      [TIN_ORE] = { cost = 31, listed = 1, at = 4000 },
    }
    local function Quote(itemID, quantity)
      asked[#asked + 1] = { itemID, quantity }
      return quotes[itemID]
    end

    local materials = ns.ShoppingList.GetMaterials(Quote)
    -- Vendor Flux and anything you already have aren't searched.
    assert.are.same({ { COPPER_ORE, 3 }, { TIN_ORE, 2 } }, asked)
    assert.are.same({
      "Bronze Bar 0 6 0 make 3 nil",
      "Copper Bar 1 3 0 make 3 nil",
      "Copper Ore 2 3 0 buy 3 86",
      "Tin Ore 1 3 1 buy 2 31",
      "Flux 0 2 0 buy 2 14",
    }, Describe(materials))
    local ore, tin = materials.rows[3], materials.rows[4]
    assert.are.same({ 13, 4000, 86 / 3 }, { ore.listed, ore.refreshedAt, ore.unitPrice })
    assert.are.same({ 1, 31 }, { tin.listed, tin.unitPrice }, "averages over what's listed")
    assert.are.equal(86 + 31 + 14, materials.cost)
    assert.are.equal(1, materials.shortCount)

    -- Nothing listed costs nothing, and isn't unpriced: it's short.
    quotes[TIN_ORE] = { cost = 0, listed = 0, at = 4000 }
    materials = ns.ShoppingList.GetMaterials(Quote)
    assert.is_nil(materials.rows[4].unitPrice)
    assert.are.same({ 0, 1, 0 }, { materials.rows[4].cost, materials.shortCount, materials.unpricedCount })

    -- A material without a Buyout is priced by its search.
    buyouts[COPPER_ORE] = nil
    assert.are.equal(86, ns.ShoppingList.GetMaterials(Quote).rows[3].cost)
    assert.are.equal("Copper Ore 2 3 0 buy 3 nil", Describe(ns.ShoppingList.GetMaterials())[3])
  end)

  it("leaves out the materials of crafts whose recipe no character knows", function()
    setfenv(1, environment)
    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 1)
    recipes[ANVIL] = { { recipeKey = "other", outputItemID = ANVIL, outputQuantity = 1, reagents = {} } }
    assert.is_nil(ns.ShoppingList.GetRecipe(ANVIL, "anvil"))
    assert.are.same({}, ns.ShoppingList.GetMaterials().rows)
    assert.are.equal(1, ns.ShoppingList.GetCount(ANVIL), "keeps the craft in case it's learned again")

    -- A made material whose recipe is forgotten is bought instead.
    recipes[ANVIL] = nil
    ns.ShoppingList.Clear()
    choices[ANVIL] = { [COPPER_BAR] = "smelt-copper" }
    recipes[ANVIL] = {
      {
        recipeKey = "anvil",
        outputItemID = ANVIL,
        outputQuantity = 1,
        reagents = { { itemID = COPPER_BAR, quantity = 2, name = "Copper Bar" } },
      },
    }
    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 1)
    recipes[COPPER_BAR] = nil
    assert.are.same({ "Copper Bar 0 2 0 buy 2 120" }, Describe(ns.ShoppingList.GetMaterials()))
  end)

  it("buys a material where making it would lead back to itself", function()
    setfenv(1, environment)
    -- Two recipes that each make the other's material, as two adds could choose.
    recipes[COPPER_ORE] = {
      {
        recipeKey = "unsmelt",
        outputItemID = COPPER_ORE,
        outputQuantity = 1,
        reagents = { { itemID = COPPER_BAR, quantity = 1, name = "Copper Bar" } },
      },
    }
    choices[ANVIL] = { [COPPER_BAR] = "smelt-copper", [COPPER_ORE] = "unsmelt" }
    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 1)

    -- The ore would need the bars being made from it, so it's bought.
    assert.are.same({
      "Coarse Stone 0 1 0 buy 1 10",
      "Copper Bar 0 2 0 make 2 nil",
      "Copper Ore 1 2 0 buy 2 50",
    }, Describe(ns.ShoppingList.GetMaterials()))
  end)

  it("buys a made material instead for every craft, and makes it again with the choices beneath it", function()
    setfenv(1, environment)
    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 1)
    ns.ShoppingList.Add(Opportunity(BRONZE_TOOL, "bronze-tool"), 1)
    changes = 0

    ns.ShoppingList.SetMake(COPPER_BAR, false)
    assert.are.equal(1, changes)
    assert.are.same({
      "Bronze Bar 0 3 0 make 2 nil",
      "Copper Bar 1 4 0 buy 4 240",
      "Tin Ore 1 2 0 buy 2 60",
      "Coarse Stone 0 1 0 buy 1 10",
      "Flux 0 1 0 buy 1 nil",
    }, Describe(ns.ShoppingList.GetMaterials()))
    ns.ShoppingList.SetMake(COPPER_BAR, false)
    assert.are.equal(1, changes, "changes nothing when it's already bought")

    ns.ShoppingList.SetMake(BRONZE_BAR, false)
    ns.ShoppingList.SetMake(COPPER_BAR, true)
    ns.ShoppingList.SetMake(BRONZE_BAR, true)
    assert.are.equal(4, changes)
    assert.are.same({
      "Bronze Bar 0 3 0 make 2 nil",
      "Copper Bar 1 4 0 make 4 nil",
      "Copper Ore 2 4 0 buy 4 100",
      "Tin Ore 1 2 0 buy 2 60",
      "Coarse Stone 0 1 0 buy 1 10",
      "Flux 0 1 0 buy 1 nil",
    }, Describe(ns.ShoppingList.GetMaterials()))
    ns.ShoppingList.SetMake(BRONZE_BAR, true)
    assert.are.equal(4, changes, "changes nothing when it's already made")
  end)

  it("makes a bought material with its cheapest recipe, choosing for the materials beneath it", function()
    setfenv(1, environment)
    choices[BRONZE_TOOL] = { [BRONZE_BAR] = false }
    choices[BRONZE_BAR] = { [COPPER_BAR] = false }
    ns.ShoppingList.Add(Opportunity(BRONZE_TOOL, "bronze-tool"), 1)
    local rows = ns.ShoppingList.GetMaterials().rows
    assert.are.same({ true, false }, { rows[1].canMake, rows[2].canMake }, "Bronze Bars can be made; Flux can't")

    ns.ShoppingList.SetMake(BRONZE_BAR, true)
    assert.are.same({ BRONZE_BAR, "smelt-bronze", true }, choiceRequests[#choiceRequests])
    assert.are.same({
      "Bronze Bar 0 3 0 make 2 nil",
      "Copper Bar 1 2 0 buy 2 120",
      "Tin Ore 1 2 0 buy 2 60",
      "Flux 0 1 0 buy 1 nil",
    }, Describe(ns.ShoppingList.GetMaterials()))

    -- Without a price for any recipe, it takes the first by key.
    ns.ShoppingList.SetMake(BRONZE_BAR, false)
    scanPlans[BRONZE_BAR] = { isUnknown = true }
    recipes[BRONZE_BAR][2] = { recipeKey = "a-first", outputItemID = BRONZE_BAR, outputQuantity = 1, reagents = {} }
    ns.ShoppingList.SetMake(BRONZE_BAR, true)
    assert.are.same({ BRONZE_BAR, "a-first", true }, choiceRequests[#choiceRequests])

    -- Nothing changes for a material no character can make.
    changes = 0
    ns.ShoppingList.SetMake(FLUX, true)
    assert.are.equal(0, changes)
  end)

  it("compares making and buying some of a material, at refreshed prices where it has them", function()
    setfenv(1, environment)
    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 1)
    ns.ShoppingList.Add(Opportunity(BRONZE_TOOL, "bronze-tool"), 1)
    -- Two Copper Bars are smelted from two ore at 25c, or bought at 60c.
    assert.are.same({
      recipeKey = "smelt-copper",
      makeTotal = 50,
      makeRefreshed = false,
      buyTotal = 120,
      buyRefreshed = false,
      buySource = "auction",
    }, ns.ShoppingList.CompareMakeAndBuy(COPPER_BAR, 2))

    local quotes = {
      [COPPER_ORE] = { cost = 56, listed = 10, at = 4000 },
      [COPPER_BAR] = { cost = 130, listed = 2, at = 4000 },
    }
    local function Quote(itemID)
      return quotes[itemID]
    end
    local comparison = ns.ShoppingList.CompareMakeAndBuy(COPPER_BAR, 2, Quote)
    assert.are.same({ 56, true, 130, true }, {
      comparison.makeTotal,
      comparison.makeRefreshed,
      comparison.buyTotal,
      comparison.buyRefreshed,
    })

    -- Too few listed: the rest at the Buyout, which isn't a refreshed price.
    quotes[COPPER_BAR] = { cost = 62, listed = 1, at = 4000 }
    comparison = ns.ShoppingList.CompareMakeAndBuy(COPPER_BAR, 2, Quote)
    assert.are.same({ 122, false }, { comparison.buyTotal, comparison.buyRefreshed })

    -- A vendor's price is exact.
    ns.ShoppingList.SetMake(COPPER_BAR, false)
    vendorPrices[COPPER_BAR] = 50
    comparison = ns.ShoppingList.CompareMakeAndBuy(COPPER_BAR, 2, Quote)
    assert.are.same(
      { "smelt-copper", 56, 100, true, "vendor" },
      { comparison.recipeKey, comparison.makeTotal, comparison.buyTotal, comparison.buyRefreshed, comparison.buySource },
      "compares the recipe it would make them with"
    )

    -- Three Bronze Bars take two crafts: two bought Copper Bars and two Tin Ore at 30c.
    comparison = ns.ShoppingList.CompareMakeAndBuy(BRONZE_BAR, 3)
    assert.are.same({ 2 * 50 + 2 * 30, 270 }, { comparison.makeTotal, comparison.buyTotal })
    ns.ShoppingList.SetMake(COPPER_BAR, true)
    comparison = ns.ShoppingList.CompareMakeAndBuy(BRONZE_BAR, 3)
    assert.are.equal(2 * 25 + 2 * 30, comparison.makeTotal, "makes the Copper Bars as the list does")

    assert.are.same({ makeRefreshed = false, buyRefreshed = false }, ns.ShoppingList.CompareMakeAndBuy(FLUX, 1))
  end)

  it("searches every material the crafts could need, made or bought, for the most they could need", function()
    setfenv(1, environment)
    choices[BRONZE_TOOL] = { [BRONZE_BAR] = false }
    ns.ShoppingList.Add(Opportunity(BRONZE_TOOL, "bronze-tool"), 1)
    -- Bought, the Bronze Bars need nothing else; made, they'd take two crafts.
    assert.are.same({
      { itemID = COPPER_BAR, quantity = 2 },
      { itemID = BRONZE_BAR, quantity = 3 },
      { itemID = COPPER_ORE, quantity = 2 },
      { itemID = TIN_ORE, quantity = 2 },
      { itemID = FLUX, quantity = 1 },
    }, ns.ShoppingList.GetSearchList())

    -- Every recipe counts, by whichever needs most: Copper Bars could also be alloyed from 3 Tin Ore.
    recipes[COPPER_BAR][2] = {
      recipeKey = "alloy",
      outputItemID = COPPER_BAR,
      outputQuantity = 1,
      reagents = { { itemID = TIN_ORE, quantity = 3 } },
    }
    owned[COPPER_ORE] = 1
    vendorPrices[FLUX] = 7
    assert.are.same({
      { itemID = COPPER_BAR, quantity = 2 },
      { itemID = BRONZE_BAR, quantity = 3 },
      { itemID = COPPER_ORE, quantity = 1 },
      { itemID = TIN_ORE, quantity = 2 + 6 },
    }, ns.ShoppingList.GetSearchList(), "leaves out what you have and what vendors sell for less")

    owned[BRONZE_BAR] = 3
    assert.are.same({}, ns.ShoppingList.GetSearchList(), "needs nothing beneath what you have enough of")
  end)

  it("makes or buys every material as costs least at refreshed prices", function()
    setfenv(1, environment)
    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 1)
    ns.ShoppingList.Add(Opportunity(BRONZE_TOOL, "bronze-tool"), 1)
    local function UnitPrice() end
    -- At refreshed prices, the Copper Bars are cheaper bought, and the Bronze Bars still made.
    refreshedChoices[ANVIL] = { [COPPER_BAR] = false }
    refreshedChoices[BRONZE_TOOL] = { [BRONZE_BAR] = "smelt-bronze", [COPPER_BAR] = "smelt-copper" }
    changes = 0

    ns.ShoppingList.ChooseCheapest(UnitPrice)
    assert.are.same({ ANVIL, "anvil", true, UnitPrice }, choiceRequests[#choiceRequests - 1])
    assert.are.equal(1, changes)
    -- The Anvil came first, so its choice for the Copper Bars stands.
    assert.are.same({
      "Bronze Bar 0 3 0 make 2 nil",
      "Copper Bar 1 4 0 buy 4 240",
      "Tin Ore 1 2 0 buy 2 60",
      "Coarse Stone 0 1 0 buy 1 10",
      "Flux 0 1 0 buy 1 nil",
    }, Describe(ns.ShoppingList.GetMaterials()))

    ns.ShoppingList.ChooseCheapest(UnitPrice)
    assert.are.equal(1, changes, "changes nothing when every choice is already the cheapest")
  end)

  it("sorts by the recipe's name while an item's name loads", function()
    setfenv(1, environment)
    names[COARSE_STONE] = nil
    names[COPPER_BAR] = nil
    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 1)
    local rows = ns.ShoppingList.GetMaterials().rows
    assert.are.same({ "Coarse Stone", "Copper Bar", "Copper Ore" }, { rows[1].name, rows[2].name, rows[3].name })
  end)
end)

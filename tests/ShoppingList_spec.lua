local NewEnvironment = dofile("tests/support/Environment.lua")

describe("ShoppingList", function()
  local environment
  local ns, realmName, recipes, choices, choiceRequests, buyouts, vendorPrices, owned, names, changes

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
        GetChoices = function(itemID, recipeKey, atBuyout)
          choiceRequests[#choiceRequests + 1] = { itemID, recipeKey, atBuyout }
          return choices[itemID]
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

  it("sorts by the recipe's name while an item's name loads", function()
    setfenv(1, environment)
    names[COARSE_STONE] = nil
    names[COPPER_BAR] = nil
    ns.ShoppingList.Add(Opportunity(ANVIL, "anvil"), 1)
    local rows = ns.ShoppingList.GetMaterials().rows
    assert.are.same({ "Coarse Stone", "Copper Bar", "Copper Ore" }, { rows[1].name, rows[2].name, rows[3].name })
  end)
end)

local _, ns = ...

ns.Crafting = {}

local function AddReason(reasons, reason)
  for _, existing in ipairs(reasons) do
    if existing == reason then
      return
    end
  end
  reasons[#reasons + 1] = reason
end

local function AddPlan(target, source, multiplier)
  target.cost = target.cost + source.cost * multiplier
  target.isUncertain = target.isUncertain or source.isUncertain

  for _, reason in ipairs(source.reasons) do
    AddReason(target.reasons, reason)
  end

  for itemID, leaf in pairs(source.leaves) do
    local targetLeaf = target.leaves[itemID]
    if targetLeaf == nil then
        targetLeaf = {
          itemID = leaf.itemID,
          name = leaf.name,
          quantity = 0,
          price = leaf.price,
          source = leaf.source,
        }
      target.leaves[itemID] = targetLeaf
    end
    targetLeaf.quantity = targetLeaf.quantity + leaf.quantity * multiplier
  end
end

local function CreatePurchasePlan(itemID, name, priceInfo)
  local reasons = {}
  for _, reason in ipairs(priceInfo.reasons or {}) do
    AddReason(reasons, reason)
  end

  return {
    cost = priceInfo.value,
    leaves = {
      [itemID] = {
        itemID = itemID,
        name = name,
        quantity = 1,
        price = priceInfo.value,
        source = priceInfo.source or "auction",
      },
    },
    reasons = reasons,
    isUncertain = priceInfo.isUncertain or false,
  }
end

local function NormalizePrice(priceInfo)
  if type(priceInfo) == "number" then
    return { value = priceInfo }
  end
  return priceInfo
end

function ns.Crafting.Calculate(itemID, recipeLookup, priceLookup)
  -- ponytail: recompute per branch; cache only with a cycle-safe graph solver.
  local visiting = {}

  local function CalculateCraft(craftItemID)
    if visiting[craftItemID] then
      return nil
    end

    visiting[craftItemID] = true
    local best
    for _, recipe in ipairs(recipeLookup(craftItemID)) do
      local outputQuantity = recipe.outputQuantity
      if outputQuantity and outputQuantity > 0 then
        local plan = {
          cost = 0,
          leaves = {},
          reasons = {},
          isUncertain = false,
        }
        local valid = true

        for _, reagent in ipairs(recipe.reagents) do
          local priceInfo = NormalizePrice(priceLookup(reagent.itemID))
          local crafted = CalculateCraft(reagent.itemID)
          local acquired

          if priceInfo and crafted then
            if crafted.cost < priceInfo.value then
              acquired = crafted
            else
              acquired = CreatePurchasePlan(reagent.itemID, reagent.name, priceInfo)
            end
          elseif priceInfo then
            acquired = CreatePurchasePlan(reagent.itemID, reagent.name, priceInfo)
          else
            acquired = crafted
          end

          if acquired == nil then
            valid = false
            break
          end

          AddPlan(plan, acquired, reagent.quantity / outputQuantity)
        end

        if valid and (best == nil or plan.cost < best.cost) then
          best = plan
        end
      end
    end
    visiting[craftItemID] = nil
    return best
  end

  local recipes = recipeLookup(itemID)
  if #recipes == 0 then
    return nil
  end

  return CalculateCraft(itemID)
end

local function GetPurchasePrice(itemID, auctionPriceLookup)
  local auctionPrice = NormalizePrice(auctionPriceLookup(itemID))
  local vendorPrice = ns.Database.GetVendorPrice(itemID)

  if vendorPrice and (auctionPrice == nil or vendorPrice < auctionPrice.value) then
    return { value = vendorPrice, source = "vendor" }
  end

  if auctionPrice then
    auctionPrice.source = "auction"
  end
  return auctionPrice
end

local function GetCost(itemLink, auctionPriceLookup)
  local itemID = C_Item.GetItemInfoInstant(itemLink)
  if itemID == nil then
    return nil
  end

  local plan = ns.Crafting.Calculate(itemID, ns.RecipeBook.GetRecipes, function(reagentItemID)
    return GetPurchasePrice(reagentItemID, auctionPriceLookup)
  end)
  if plan == nil then
    if #ns.RecipeBook.GetRecipes(itemID) > 0 then
      return { isUnknown = true }
    end
    return nil
  end

  plan.value = math.floor(plan.cost + 0.5)
  return plan
end

function ns.Crafting.GetCost(itemLink)
  return GetCost(itemLink, function(reagentItemID)
    return ns.Database.GetRollingMarketValue({ tostring(reagentItemID) })
  end)
end

function ns.Crafting.GetMinimumCost(itemLink)
  return GetCost(itemLink, function(reagentItemID)
    return ns.Database.GetLatestBuyout({ tostring(reagentItemID) })
  end)
end

local _, ns = ...

-- The labels and definitions for the terms used across Arbitrage.
ns.Terminology = {}

---@class ArbitrageTerm
---@field label string what players see as the name
---@field definition string a full sentence explaining it

---@type ArbitrageTerm
ns.Terminology.vendor = {
  label = "Vendor",
  definition = "What a vendor pays for each unit of the item.",
}

---@type ArbitrageTerm
ns.Terminology.typical = {
  label = "Typical",
  definition = "The item's usual price over the last 14 days.",
}

---@type ArbitrageTerm
ns.Terminology.current = {
  label = "Current",
  definition = "The item's cheapest listing price in the latest scan.",
}

---@type ArbitrageTerm
ns.Terminology.typicalCraftCost = {
  label = "Typical Craft Cost",
  definition = "Cheapest way to make one item at Typical prices, including vendors and intermediate crafts.",
}

---@type ArbitrageTerm
ns.Terminology.currentCraftCost = {
  label = "Current Craft Cost",
  definition = "Cheapest way to make one item at Current prices, including vendors and intermediate crafts.",
}

---@type ArbitrageTerm
ns.Terminology.typicalProfit = {
  label = "Typical Profit",
  definition = "Profit from crafting and selling an item at Typical prices, or to a vendor when that pays more. Accounts for the 5% Auction House cut.",
}

---@type ArbitrageTerm
ns.Terminology.currentProfit = {
  label = "Current Profit",
  definition = "Profit from crafting and selling an item at Current prices, or to a vendor when that pays more. Accounts for the 5% Auction House cut.",
}

---@type ArbitrageTerm
ns.Terminology.typicalRoi = {
  label = "Typical ROI",
  definition = "Return on investment at Typical prices: Typical Profit as a share of Typical Craft Cost. At +100%, a sale brings in twice what crafting it cost.",
}

---@type ArbitrageTerm
ns.Terminology.currentRoi = {
  label = "Current ROI",
  definition = "Return on investment at Current prices: Current Profit as a share of Current Craft Cost.",
}

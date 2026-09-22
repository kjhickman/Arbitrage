local NewHarness = assert(loadfile("tests/support/AuctionHouseHarness.lua"), "loads AuctionHouseHarness.lua")()
local harness = NewHarness()

harness.FireEvent("AUCTION_HOUSE_SHOW")
local components = harness.FindComponents()
local headers = components.headers
local scrollBox = components.scrollBox
local scrollBar = components.scrollBar

assert(scrollBox and scrollBox.parent == components.tableBackground, "creates a native Auction House scroll box")
assert(scrollBar and scrollBar.parent == components.tableBackground, "creates the Forever Auction House scrollbar")
assert(scrollBox.scrollBar == scrollBar, "connects the opportunity list to its scrollbar")
assert(
  scrollBox.view and scrollBox.view.template == "AuctionHouseItemListLineTemplate",
  "uses the native Auction House row template"
)
assert(
  headers["Item / Crafter"]
    and headers["Net Sale"]
    and headers["Craft Cost"]
    and headers["Min Cost"]
    and headers["Est. Profit"]
    and headers["Best Profit"]
    and headers.ROI,
  "creates an Auction House-style header for every table column"
)
for _, header in pairs(headers) do
  assert(type(header.scripts.OnClick) == "function", "makes every table column sortable")
end

components.tab:Click()

local opportunityRows = {}
for _, createdFrame in ipairs(harness.createdFrames) do
  if createdFrame.parent == scrollBox and createdFrame.template == "AuctionHouseItemListLineTemplate" then
    opportunityRows[#opportunityRows + 1] = createdFrame
  end
end
assert(#opportunityRows >= 2, "creates compact rows for visible opportunities")
assert(opportunityRows[1].scripts.OnClick == nil, "removes the incompatible native row click handler")
assert(opportunityRows[1].icon.width == 14 and opportunityRows[1].icon.height == 14, "matches native item icon sizing")
assert(
  opportunityRows[1].iconBorder.atlas == "auctionhouse-itemicon-small-border"
    and opportunityRows[1].iconBorder.width == 16
    and opportunityRows[1].iconBorder.height == 16,
  "uses the native Auction House item icon border"
)
assert(
  opportunityRows[1].normalTexture.atlas == "auctionhouse-rowstripe-2"
    and opportunityRows[2].normalTexture.atlas == "auctionhouse-rowstripe-1",
  "alternates native Auction House row stripes"
)

local itemName
local sourceText
local marketText
local costText
local minimumCostText
local profitText
local minimumProfitText
local roiText
local missingValueCount = 0
for _, fontString in ipairs(harness.createdFontStrings) do
  if fontString.text == "Flask (x2)" then
    itemName = fontString
  elseif fontString.text == "Alchemy - Alt, Main" then
    sourceText = fontString
  elseif fontString.text == "190c" then
    marketText = fontString
  elseif fontString.text == "80c" then
    costText = fontString
  elseif fontString.text == "60c" then
    minimumCostText = fontString
  elseif fontString.text == "+110c" then
    profitText = fontString
  elseif fontString.text == "+130c" then
    minimumProfitText = fontString
  elseif fontString.text == "138%" then
    roiText = fontString
  elseif fontString.text == "—" then
    missingValueCount = missingValueCount + 1
  end
end
assert(itemName and sourceText, "shows the product, output quantity, profession, and crafters")
assert(not itemName.wordWrap and itemName.maxLines == 1, "keeps item names within one row")
assert(not sourceText.wordWrap and sourceText.maxLines == 1, "keeps long crafter lists within one row")
assert(
  marketText and costText and minimumCostText and profitText and minimumProfitText and roiText,
  "shows sale, both costs, both profits, and ROI in separate cells"
)
assert(missingValueCount >= 2, "shows missing minimum values explicitly")
assert(headers["Est. Profit"].Arrow.shown, "marks estimated profit as the default sort")
assert(opportunityRows[1]:GetElementData().itemID == 100, "sorts estimated profit descending by default")
assert(
  opportunityRows[2].market.textColor[2] == 0.82
    and opportunityRows[2].profit.textColor[2] == 0.82
    and opportunityRows[2].roi.textColor[2] == 0.82
    and opportunityRows[2].roi.text == "6%",
  "colors uncertain market-derived values and ROI yellow"
)
assert(opportunityRows[2].cost.textColor[2] == 1, "keeps reliable values white in an otherwise uncertain row")
assert(harness.requestedItemIDs[1] == 200, "requests missing item display data")

opportunityRows[1].scripts.OnEnter(opportunityRows[1])
assert(
  harness.tooltipLines[#harness.tooltipLines] == "Crafted by: Alchemy - Alt, Main",
  "shows the complete crafter list on hover"
)
opportunityRows[1].scripts.OnLeave(opportunityRows[1])

harness.itemInfo[200] = { "Widget", "item:200", 1, 1, 1, "", "", 20, "", 2000 }
harness.FireEvent("GET_ITEM_INFO_RECEIVED", 200, true)
assert(harness.GetOpportunityCalls() == 1, "rerenders without recalculating when requested item data loads")
local loadedName
for _, fontString in ipairs(harness.createdFontStrings) do
  if fontString.text == "Widget" then
    loadedName = fontString
  end
end
assert(loadedName, "refreshes rows when requested item data loads")

harness.FireEvent("GET_ITEM_INFO_RECEIVED", 999, true)
assert(harness.GetOpportunityCalls() == 1, "ignores unrelated item data events")

harness.itemInfo[1] = { "Alpha", "item:1", 1, 1, 1, "", "", 20, "", 1 }
harness.itemInfo[2] = { "Bravo", "item:2", 1, 1, 1, "", "", 20, "", 2 }
harness.itemInfo[3] = { "Charlie", "item:3", 1, 1, 1, "", "", 20, "", 3 }
local sortableItems = {
  {
    itemID = 3,
    outputQuantity = 1,
    saleProceeds = 40,
    craftCost = 10,
    minimumCraftCost = 5,
    profit = 30,
    minimumProfit = 35,
    roi = 3,
    sources = {},
    reasons = {},
    isUncertain = false,
  },
  {
    itemID = 1,
    outputQuantity = 1,
    saleProceeds = 30,
    craftCost = 20,
    minimumCraftCost = 15,
    profit = 10,
    minimumProfit = 15,
    roi = 0.5,
    sources = {},
    reasons = {},
    isUncertain = false,
  },
  {
    itemID = 2,
    outputQuantity = 1,
    saleProceeds = 50,
    craftCost = 40,
    profit = 5,
    roi = 0.125,
    sources = {},
    reasons = {},
    isUncertain = false,
  },
}
harness.SetOpportunityResult({ totalCount = 3, pricedCount = 3, items = sortableItems })
harness.ns.AuctionHouse.Refresh()

local function AssertColumnSort(label, firstDefault, firstReversed)
  headers[label]:Click()
  assert(opportunityRows[1]:GetElementData().itemID == firstDefault, label .. " uses its default sort direction")
  assert(headers[label].Arrow.shown, label .. " shows its active sort arrow")
  headers[label]:Click()
  assert(opportunityRows[1]:GetElementData().itemID == firstReversed, label .. " reverses on a second click")
end

AssertColumnSort("Item / Crafter", 1, 3)
AssertColumnSort("Net Sale", 2, 1)
AssertColumnSort("Craft Cost", 2, 3)
AssertColumnSort("Min Cost", 1, 3)
AssertColumnSort("Est. Profit", 3, 2)
AssertColumnSort("Best Profit", 3, 1)
AssertColumnSort("ROI", 3, 2)

harness.itemInfo[1][1] = "Zulu"
harness.itemInfo[2] = nil
headers["Item / Crafter"]:Click()
assert(opportunityRows[1]:GetElementData().itemID == 3, "sorts known item names ahead of unresolved names")
harness.itemInfo[2] = { "Alpha", "item:2", 1, 1, 1, "", "", 20, "", 2 }
harness.FireEvent("GET_ITEM_INFO_RECEIVED", 2, true)
assert(opportunityRows[1]:GetElementData().itemID == 2, "reapplies item sorting when a requested name loads")
headers["Est. Profit"]:Click()

local scrollingItems = {}
for itemID = 1, 17 do
  scrollingItems[itemID] = {
    itemID = itemID,
    outputQuantity = 1,
    saleProceeds = 100,
    craftCost = 50,
    profit = 50,
    roi = 1,
    sources = {},
    reasons = {},
    isUncertain = false,
  }
end
scrollingItems[17].profit = -1
scrollingItems[17].minimumProfit = 1
harness.SetOpportunityResult({ totalCount = 17, pricedCount = 17, items = scrollingItems })
harness.ns.AuctionHouse.Refresh()
opportunityRows[1].scripts.OnEnter(opportunityRows[1])
local hideCallsBeforeScroll = harness.GetTooltipHideCalls()
scrollBox:SetScrollOffset(1)
assert(
  scrollBox.frames[16].profit.text == "-1c",
  "formats a bottom-row estimated loss without passing it to the coin formatter"
)
assert(harness.GetTooltipHideCalls() == hideCallsBeforeScroll + 1, "hides a stale row tooltip when scrolling")
harness.itemInfo[2] = { "Loaded Item", "item:2", 1, 1, 1, "", "", 20, "", 2000 }
harness.FireEvent("GET_ITEM_INFO_RECEIVED", 2, true)
assert(opportunityRows[1]:GetElementData().itemID == 2, "preserves the scroll position after item data loads")

local itemFourRequestCount = 0
for _, requestedItemID in ipairs(harness.requestedItemIDs) do
  if requestedItemID == 4 then
    itemFourRequestCount = itemFourRequestCount + 1
  end
end
harness.FireEvent("GET_ITEM_INFO_RECEIVED", 4, false)
harness.ns.AuctionHouse.Refresh()
local itemFourRetryCount = 0
for _, requestedItemID in ipairs(harness.requestedItemIDs) do
  if requestedItemID == 4 then
    itemFourRetryCount = itemFourRetryCount + 1
  end
end
assert(itemFourRetryCount == itemFourRequestCount + 1, "retries item display data after a failed load")

opportunityRows[1].scripts.OnEnter(opportunityRows[1])
local hideCallsBeforeRefresh = harness.GetTooltipHideCalls()
harness.SetOpportunityResult({ totalCount = 0, pricedCount = 0, items = {} })
harness.ns.AuctionHouse.Refresh()
assert(harness.GetTooltipHideCalls() == hideCallsBeforeRefresh + 1, "hides its tooltip before replacing ranked results")

local _, ns = ...

-- Adds what you're looking at in the Auction House's Buy tab to the shopping list: a button under
-- Buy Now for a commodity, taking the quantity typed beside it, one beside your gold for any other
-- item, and an entry in the menu a right-click on a result opens, after Blizzard's Favorites.
ns.AuctionHouseBuy = {}

local LABEL = "Add to Shopping List"
-- Blizzard's tag for the menu a result or the item at the top of the Buy tab opens.
local MENU_TAG = "MENU_AUCTION_HOUSE_FAVORITE"
local COMMODITY_BUTTON_WIDTH = 196
local ITEM_BUTTON_WIDTH = 160
local BUTTON_HEIGHT = 22

-- Says what was added, since nothing else in the Buy tab shows the list.
---@param itemID number?
---@param count number
local function Add(itemID, count)
  if not itemID or not ns.ShoppingList.AddItem(itemID, count) then
    return
  end
  local _, link = C_Item.GetItemInfo(itemID)
  ns.Print(("Added %s x%d to your shopping list."):format(link or ("item " .. itemID), count))
end

---@param parent Frame
---@param width number
---@param onClick fun()
---@return Button
local function CreateButton(parent, width, onClick)
  local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  button:SetSize(width, BUTTON_HEIGHT)
  button:SetText(LABEL)
  button:SetScript("OnClick", onClick)
  return button
end

-- Blizzard's Buy tab loads with its Auction House UI, the first time the Auction House opens.
local function CreateButtons()
  local auctionHouse = AuctionHouseFrame
  -- Below Buy Now, in the room Blizzard leaves under it.
  local display = auctionHouse.CommoditiesBuyFrame.BuyDisplay
  CreateButton(display, COMMODITY_BUTTON_WIDTH, function()
    Add(display:GetItemID(), math.max(display:GetQuantitySelected() or 1, 1))
  end):SetPoint("TOP", display.BuyButton, "BOTTOM", 0, -8)

  -- Buyout and Bid fill the bottom right, so this sits at the bottom left, past your gold.
  local itemBuyFrame = auctionHouse.ItemBuyFrame
  CreateButton(itemBuyFrame, ITEM_BUTTON_WIDTH, function()
    local itemKey = itemBuyFrame.ItemDisplay:GetItemKey()
    Add(itemKey and itemKey.itemID, 1)
  end):SetPoint("LEFT", auctionHouse.MoneyFrameBorder, "RIGHT", 10, 0)
end

-- The menu's owner is the result's row, which holds its item key in its data, or the item at the
-- top of the Buy tab, which has its own.
---@param owner table
---@return number?
local function ItemIDOf(owner)
  local itemKey
  if owner.GetRowData then
    local rowData = owner:GetRowData()
    itemKey = rowData and rowData.itemKey
  elseif owner.GetItemKey then
    itemKey = owner:GetItemKey()
  end
  return itemKey and itemKey.itemID
end

function ns.AuctionHouseBuy.Register()
  Menu.ModifyMenu(MENU_TAG, function(owner, rootDescription)
    local itemID = ItemIDOf(owner)
    if not itemID then
      return
    end
    rootDescription:CreateDivider()
    rootDescription:CreateButton(LABEL, function()
      Add(itemID, 1)
    end)
  end)
  EventUtil.ContinueOnAddOnLoaded("Blizzard_AuctionHouseUI", CreateButtons)
end

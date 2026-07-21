local _, ns = ...

ns.Vendor = {}

local frame = CreateFrame("Frame")

function ns.Vendor.CacheMerchantPrices()
  for index = 1, GetMerchantNumItems() do
    local itemID = GetMerchantItemID(index)
    local _, _, price, quantity, numAvailable, isPurchasable, _, extendedCost = GetMerchantItemInfo(index)

    if
      itemID
      and price
      and price > 0
      and price < math.huge
      and quantity
      and quantity > 0
      and quantity < math.huge
      and numAvailable == -1
      and isPurchasable ~= false
      and not extendedCost
    then
      ns.Database.RecordVendorPrice(itemID, price / quantity)
    end
  end
end

function ns.Vendor.Register()
  frame:RegisterEvent("MERCHANT_SHOW")
  frame:RegisterEvent("MERCHANT_UPDATE")
  frame:SetScript("OnEvent", ns.Vendor.CacheMerchantPrices)
end

local _, ns = ...

ns.Time = {}

local MINUTE = 60
local HOUR = 60 * MINUTE
local DAY = 24 * HOUR

---@param count number
---@param unit string
---@return string
local function Ago(count, unit)
  return count .. " " .. unit .. (count == 1 and "" or "s") .. " ago"
end

-- A status line reads better as an age than as a date the player has to compare against a clock.
-- Scans are pruned at 30 days, so days are the largest unit worth spelling out. A timestamp from
-- the future, which clock drift between a scan and the local machine can produce, reads as now.
---@param timestamp number
---@return string
function ns.Time.Since(timestamp)
  local seconds = time() - timestamp

  if seconds < MINUTE then
    return "just now"
  end
  if seconds < HOUR then
    return Ago(math.floor(seconds / MINUTE), "minute")
  end
  if seconds < DAY then
    return Ago(math.floor(seconds / HOUR), "hour")
  end

  return Ago(math.floor(seconds / DAY), "day")
end

local originalLoadfile = loadfile
local assert = require("luassert")

return function()
  local environment = setmetatable({}, { __index = _G })
  environment._G = environment
  environment.assert = assert

  function environment.loadfile(path)
    local chunk, message = originalLoadfile(path)
    if chunk then
      setfenv(chunk, environment)
    end
    return chunk, message
  end

  return environment
end

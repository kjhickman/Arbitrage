local NewEnvironment = dofile("tests/support/Environment.lua")

describe("MinimapButton", function()
  local environment
  local icon
  local windowToggleCount
  local settingsOpenCount
  local ns

  before_each(function()
    environment = NewEnvironment()
    setfenv(1, environment)
    windowToggleCount = 0
    settingsOpenCount = 0

    strmatch = string.match
    function securecallfunction(callback, ...)
      return callback(...)
    end

    NORMAL_FONT_COLOR = {
      GetRGB = function()
        return 1, 0.82, 0
      end,
    }

    assert(loadfile("libs/LibAHTab/LibStub/LibStub.lua"), "loads LibStub")()
    assert(loadfile("libs/LibDBIcon-1.0/CallbackHandler-1.0/CallbackHandler-1.0.lua"), "loads CallbackHandler")()
    assert(loadfile("libs/LibDBIcon-1.0/LibDataBroker-1.1/LibDataBroker-1.1.lua"), "loads LibDataBroker")()

    -- LibDBIcon needs the minimap, so this stands in for it, showing the button as LibDBIcon does.
    icon = LibStub:NewLibrary("LibDBIcon-1.0", 1)
    function icon:Register(name, object, db)
      assert.is_nil(self.name, "registers once")
      self.name, self.object, self.db = name, object, db
      self.shown = not db.hide
    end
    function icon:Refresh(name)
      assert.are.equal(self.name, name)
      self.shown = not self.db.hide
    end

    ARBITRAGE_CONFIG = nil
    ns = {
      Window = {
        Toggle = function()
          windowToggleCount = windowToggleCount + 1
        end,
      },
    }
    assert(loadfile("src/Terminology.lua"), "loads Terminology.lua")("Arbitrage", ns)
    assert(loadfile("src/Config.lua"), "loads Config.lua")("Arbitrage", ns)
    ns.Config.Init()
    ns.Config.OpenOptionsPanel = function()
      settingsOpenCount = settingsOpenCount + 1
    end
    assert(loadfile("src/MinimapButton.lua"), "loads MinimapButton.lua")("Arbitrage", ns)
  end)

  it("registers an Arbitrage launcher that is hidden until turned on", function()
    setfenv(1, environment)
    ns.MinimapButton.Register()

    assert.are.equal("Arbitrage", icon.name)
    assert.are.equal("launcher", icon.object.type)
    assert.are.equal("Interface\\AddOns\\Arbitrage\\media\\icon", icon.object.icon)
    assert.are.equal(ARBITRAGE_CONFIG.minimapButton, icon.db)
    assert.is_false(icon.shown)
  end)

  it("shows and hides the button when the setting changes, keeping where it was dragged", function()
    setfenv(1, environment)
    ns.MinimapButton.Register()
    icon.db.minimapPos = 140

    ARBITRAGE_CONFIG.showMinimapButton = true
    ns.MinimapButton.Refresh()
    assert.is_true(icon.shown)

    ARBITRAGE_CONFIG.showMinimapButton = false
    ns.MinimapButton.Refresh()
    assert.is_false(icon.shown)
    assert.are.equal(140, ARBITRAGE_CONFIG.minimapButton.minimapPos)
  end)

  it("shows the button at login when it was left on", function()
    setfenv(1, environment)
    ARBITRAGE_CONFIG = { showMinimapButton = true, minimapButton = { minimapPos = 140, hide = true } }
    ns.Config.Init()
    ns.MinimapButton.Register()
    assert.is_true(icon.shown)
    assert.are.equal(140, icon.db.minimapPos)
  end)

  it("toggles the window on left-click and opens settings on right-click", function()
    setfenv(1, environment)
    ns.MinimapButton.Register()

    icon.object.OnClick({}, "LeftButton")
    assert.are.equal(1, windowToggleCount)
    assert.are.equal(0, settingsOpenCount)

    icon.object.OnClick({}, "RightButton")
    assert.are.equal(1, windowToggleCount)
    assert.are.equal(1, settingsOpenCount)
  end)

  it("explains both clicks in its tooltip", function()
    setfenv(1, environment)
    ns.MinimapButton.Register()
    local lines = {}
    icon.object.OnTooltipShow({
      AddLine = function(_, text)
        lines[#lines + 1] = text
      end,
    })
    assert.are.same({
      "Arbitrage",
      "Left-click: Toggle the Arbitrage window",
      "Right-click: Open settings",
    }, lines)
  end)
end)

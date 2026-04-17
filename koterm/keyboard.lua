--[[
    keyboard/softkey.lua — e-ink friendly soft keyboard for inkterm.

    Renders a compact keyboard widget below the terminal grid. Because e-ink
    refresh is slow, the layout avoids hover states and uses large tap targets.
    Modifier keys (Ctrl, Alt, Esc) are toggle-latching: tap once to arm,
    tap a normal key to fire the combo, then auto-release.

    Layout layers:
        normal      — default alpha/num/sym
        shift       — uppercase + shifted symbols
        ctrl        — Ctrl-key combos  (sends 0x01–0x1A)
        alt         — Alt-key combos   (sends ESC + char)
        sym         — extra symbols page

    Key objects: { label, key [, width_factor] }
        key can be:
            string    → send that UTF-8 string verbatim
            "\27[X"   → send escape sequence
            special:  "CTRL", "ALT", "SHIFT", "SYM", "ENTER",
                      "BACKSPACE", "TAB", "ESC", "UP", "DOWN",
                      "LEFT", "RIGHT", "PGUP", "PGDN"
--]]

local Blitbuffer  = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup   = require("ui/widget/verticalgroup")
local TextWidget      = require("ui/widget/textwidget")
local Button          = require("ui/widget/button")
local UIManager       = require("ui/uimanager")
local Font            = require("ui/font")
local Screen          = require("device/screen")
local Geom            = require("ui/geometry")
local logger          = require("logger")

-- Key layouts ─────────────────────────────────────────────────────────────────

local LAYOUTS = {}

LAYOUTS.normal = {
    { {"1","1"},{"2","2"},{"3","3"},{"4","4"},{"5","5"},
      {"6","6"},{"7","7"},{"8","8"},{"9","9"},{"0","0"} },
    { {"q","q"},{"w","w"},{"e","e"},{"r","r"},{"t","t"},
      {"y","y"},{"u","u"},{"i","i"},{"o","o"},{"p","p"} },
    { {"a","a"},{"s","s"},{"d","d"},{"f","f"},{"g","g"},
      {"h","h"},{"j","j"},{"k","k"},{"l","l"} },
    { {"SHF","SHIFT",1.5},{"z","z"},{"x","x"},{"c","c"},{"v","v"},
      {"b","b"},{"n","n"},{"m","m"},{"BSP","BACKSPACE",1.5} },
    { {"CTL","CTRL",1.3},{"ALT","ALT",1.3},{"SYM","SYM",1.3},
      {" "," ",3.5},
      {"ENT","ENTER",1.5},
      {"ESC","ESC",1.3} },
}

LAYOUTS.shift = {
    { {"!","!"},{"@","@"},{"#","#"},{"$","$"},{"%","%"},
      {"^","^"},{"&","&"},{"*","*"},{"(",")"},{")",")"}},
    { {"Q","Q"},{"W","W"},{"E","E"},{"R","R"},{"T","T"},
      {"Y","Y"},{"U","U"},{"I","I"},{"O","O"},{"P","P"} },
    { {"A","A"},{"S","S"},{"D","D"},{"F","F"},{"G","G"},
      {"H","H"},{"J","J"},{"K","K"},{"L","L"} },
    { {"SHF","SHIFT",1.5},{"Z","Z"},{"X","X"},{"C","C"},{"V","V"},
      {"B","B"},{"N","N"},{"M","M"},{"BSP","BACKSPACE",1.5} },
    { {"CTL","CTRL",1.3},{"ALT","ALT",1.3},{"SYM","SYM",1.3},
      {" "," ",3.5},
      {"ENT","ENTER",1.5},
      {"ESC","ESC",1.3} },
}

LAYOUTS.sym = {
    { {"`","`"},{"~","~"},{"\\","\\"},  {"|","|"}, {"[","["},
      {"]","]"},{"{","{"},  {"}","}"}, {"<","<"},  {">",">"} },
    { {"!","!"},{"?","?"},{"/","/"}, {";",";"},{":",":",},
      {"\"","\""},{"'","'"},{"(","("},{")",")"},{"_","_"} },
    { {"-","-"},{"=","="},{"+"," +"},{"*","*"},{"&","&"},
      {"^","^"},{"%","%"},{"$","$"},{"#","#"} },
    { {"@","@"},{"UP","\27[A",1.5},{"DWN","\27[B",1.5},
      {"LFT","\27[D",1.5},{"RGT","\27[C",1.5},
      {"PGU","\27[5~",1.5},{"PGD","\27[6~",1.5},
      {"BSP","BACKSPACE",1.5} },
    { {"CTL","CTRL",1.3},{"ALT","ALT",1.3},{"ABC","SYM",1.3},
      {"TAB","TAB",2},{"ENT","ENTER",2},{"ESC","ESC",1.5} },
}

-- ─────────────────────────────────────────────────────────────────────────────

local SoftKeyboard = {}
SoftKeyboard.__index = SoftKeyboard

function SoftKeyboard:new(o)
    o = o or {}
    setmetatable(o, SoftKeyboard)
    o._layer    = "normal"
    o._ctrl     = false
    o._alt      = false
    o._shift    = false
    o.on_key    = o.on_key or function(s) end   -- callback(str)
    o._key_h    = o._key_h or 48
    o._face     = Font:getFace("smallinfofont", 14)
    return o
end

function SoftKeyboard:_resolve_key(key, label)
    -- Returns the byte string to send, or nil if it's a modifier/action
    local ctrl  = self._ctrl
    local alt   = self._alt

    if key == "ENTER"     then return "\r" end
    if key == "BACKSPACE" then return "\127" end
    if key == "TAB"       then return "\t"  end
    if key == "ESC"       then return "\27" end
    -- Arrow / function keys — pass raw escape sequences through
    if key:sub(1,1) == "\27" then return key end

    if #key == 1 then
        local s = key
        if ctrl and s:match("[a-zA-Z@%[%\\%]%^_]") then
            local b = s:upper():byte(1)
            -- Ctrl maps A-Z to 0x01-0x1A
            if b >= 64 and b <= 95 then
                s = string.char(b - 64)
            end
        elseif alt then
            s = "\27" .. s
        end
        return s
    end

    return nil  -- modifier or unknown special key
end

function SoftKeyboard:_on_tap(key, label)
    -- Handle modifiers
    if key == "SHIFT" then
        self._shift = not self._shift
        self._layer = self._shift and "shift" or "normal"
        self:_rebuild()
        return
    end
    if key == "CTRL" then
        self._ctrl = not self._ctrl
        self:_rebuild()
        return
    end
    if key == "ALT" then
        self._alt = not self._alt
        self:_rebuild()
        return
    end
    if key == "SYM" then
        self._layer = (self._layer == "sym") and "normal" or "sym"
        self._shift = false
        self:_rebuild()
        return
    end

    local s = self:_resolve_key(key, label)
    if s then
        self.on_key(s)
        -- Auto-release latched modifiers
        if self._ctrl or self._alt then
            self._ctrl  = false
            self._alt   = false
            self:_rebuild()
        end
        if self._shift and self._layer == "shift" then
            self._shift = false
            self._layer = "normal"
            self:_rebuild()
        end
    end
end

function SoftKeyboard:_make_key_widget(label, key, width)
    local w = width or 1
    local sw = Screen:getWidth()
    -- base unit width: screen / 10 keys per row
    local base_w = math.floor(sw / 10)
    local key_w  = math.floor(base_w * w) - 4  -- 4px inter-key gap

    local is_active = (
        (key == "CTRL"  and self._ctrl)  or
        (key == "ALT"   and self._alt)   or
        (key == "SHIFT" and self._shift) or
        (key == "SYM"   and self._layer == "sym")
    )

    local bg = is_active
        and Blitbuffer.COLOR_DARK_GRAY
        or  Blitbuffer.COLOR_LIGHT_GRAY

    local btn = FrameContainer:new{
        padding    = 0,
        bordersize = 1,
        background = bg,
        width      = key_w,
        height     = self._key_h,
        CenterContainer:new{
            dimen = Geom:new{ w = key_w, h = self._key_h },
            TextWidget:new{
                text    = label,
                face    = self._face,
                fgcolor = is_active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
            },
        },
    }

    btn.key   = key
    btn.label = label

    -- Attach gesture
    btn.ges_events = {
        TapSelectKey = { GestureRange:new{ ges = "tap", range = btn.dimen } },
    }
    function btn:onTapSelectKey()
        self._kb:_on_tap(self.key, self.label)
    end
    btn._kb = self

    return btn
end

function SoftKeyboard:_rebuild()
    -- Rebuild the keyboard widget in place; caller must call UIManager:setDirty
    local layout = LAYOUTS[self._layer] or LAYOUTS.normal
    local rows = VerticalGroup:new{ align = "center" }

    for _, row_def in ipairs(layout) do
        local row = HorizontalGroup:new{ align = "center" }
        for _, key_def in ipairs(row_def) do
            local label, key, w = key_def[1], key_def[2], key_def[3]
            row[#row+1] = self:_make_key_widget(label, key, w)
        end
        rows[#rows+1] = row
    end

    if self._container then
        self._container[1] = rows
    else
        self._container = FrameContainer:new{
            padding    = 4,
            bordersize = 1,
            background = Blitbuffer.COLOR_WHITE,
            rows,
        }
    end
    self.dirty = true
end

function SoftKeyboard:getWidget()
    if not self._container then
        self:_rebuild()
    end
    return self._container
end

-- Preferred height for layout calculations
function SoftKeyboard:preferredHeight()
    local layout = LAYOUTS[self._layer] or LAYOUTS.normal
    return (#layout * (self._key_h + 4)) + 12
end

return SoftKeyboard

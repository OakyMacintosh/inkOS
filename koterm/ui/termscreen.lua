--[[
    ui/termscreen.lua — top-level full-screen terminal UI.

    Composes:
        TermWidget   — VT100 grid display + physical keyboard handler
        SoftKeyboard — on-screen keyboard (shown when no physical keyboard
                       is detected, or when toggled by the user)

    Physical keyboard detection:
        - If /proc/bus/input/devices contains a keyboard device (EV=120013
          or a device named *kbd* / *keyboard*) we default to hiding the
          soft keyboard.
        - On Kindle/Kobo the device keyboard is always the soft KB unless
          the user has a paired BT keyboard.
        - User can toggle the soft keyboard via a small button in the title bar.
--]]

local InputContainer  = require("ui/widget/container/inputcontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget      = require("ui/widget/textwidget")
local Blitbuffer      = require("ffi/blitbuffer")
local UIManager       = require("ui/uimanager")
local Screen          = require("device/screen")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local logger          = require("logger")

local PtyBackend  = require("plugins/inkterm/pty/init")
local TermWidget  = require("plugins/inkterm/ui/termwidget")
local SoftKeyboard = require("plugins/inkterm/keyboard/softkey")

-- ─────────────────────────────────────────────────────────────────────────────

local TITLEBAR_H = 36
local FACE_TITLE = Font:getFace("smallinfofont", 14)

-- ── Physical keyboard detection ──────────────────────────────────────────────

local function has_physical_keyboard()
    local f = io.open("/proc/bus/input/devices", "r")
    if not f then return false end
    local content = f:read("*a")
    f:close()
    -- Look for EV=120013 (standard US keyboard event bitmask) or name hints
    if content:match("EV=120013") then return true end
    if content:lower():match("keyboard") then return true end
    if content:lower():match("kbd")      then return true end
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────

local TermScreen = InputContainer:extend{
    name = "TermScreen",
}

function TermScreen:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()

    -- Decide soft keyboard visibility
    self._show_kb = not has_physical_keyboard()

    -- Init PTY backend
    self._pty_backend = PtyBackend:new()
    self._pty = self._pty_backend:new()

    -- Compute heights
    local kb      = SoftKeyboard:new{
        on_key = function(s) self._term:sendInput(s) end,
    }
    self._kb = kb
    local kb_h  = self._show_kb and kb:preferredHeight() or 0
    local term_h = sh - TITLEBAR_H - kb_h

    -- Open PTY
    local cols = math.floor(sw / 10)   -- rough initial estimate
    local rows = math.floor(term_h / 18)
    local ok, err = self._pty:open(cols, rows)
    if not ok then
        logger.err("inkterm: PTY open failed:", err)
        self._pty_error = err
    end

    -- Build TermWidget
    self._term = TermWidget:new{
        width     = sw,
        height    = term_h,
        kb_height = kb_h,
        pty       = self._pty,
    }

    -- Title bar
    self._title_bar = self:_build_titlebar(sw)

    -- Top-level layout
    local layout = VerticalGroup:new{
        align = "left",
        self._title_bar,
        self._term,
    }
    if self._show_kb then
        layout[#layout+1] = kb:getWidget()
    end

    self[1] = layout
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    -- Gesture: swipe up from bottom edge toggles soft keyboard
    self.ges_events.SwipeToggleKB = {
        GestureRange:new{
            ges   = "swipe",
            range = Geom:new{
                x = 0,
                y = sh - 80,
                w = sw,
                h = 80,
            },
            direction = "north",
        },
    }
end

-- ── Title bar ────────────────────────────────────────────────────────────────

function TermScreen:_build_titlebar(sw)
    local title = TextWidget:new{
        text = "inkOS Terminal",
        face = FACE_TITLE,
        bold = true,
    }

    -- KB toggle button
    local kb_btn_label = self._show_kb and "Hide KB" or "Show KB"
    local kb_btn = FrameContainer:new{
        padding    = 4,
        bordersize = 1,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        TextWidget:new{ text = kb_btn_label, face = FACE_TITLE },
    }
    kb_btn.ges_events = {
        TapKBToggle = { GestureRange:new{ ges = "tap", range = kb_btn.dimen } },
    }
    function kb_btn:onTapKBToggle()
        self._screen:_toggleSoftKB()
    end
    kb_btn._screen = self

    -- Close button
    local close_btn = FrameContainer:new{
        padding    = 4,
        bordersize = 1,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        TextWidget:new{ text = "X", face = FACE_TITLE },
    }
    close_btn.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = close_btn.dimen } },
    }
    function close_btn:onTapClose()
        self._screen:_close()
    end
    close_btn._screen = self

    local bar = FrameContainer:new{
        padding    = 4,
        bordersize = 0,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        width      = sw,
        height     = TITLEBAR_H,
        HorizontalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = sw - 140, h = TITLEBAR_H },
                title,
            },
            kb_btn,
            TextWidget:new{ text = "  ", face = FACE_TITLE },
            close_btn,
        },
    }
    return bar
end

-- ── Soft keyboard toggle ─────────────────────────────────────────────────────

function TermScreen:_toggleSoftKB()
    self._show_kb = not self._show_kb
    -- Rebuild is done by re-showing the screen
    UIManager:close(self)
    self:init()
    UIManager:show(self)
end

function TermScreen:onSwipeToggleKB()
    self:_toggleSoftKB()
    return true
end

-- ── Close ────────────────────────────────────────────────────────────────────

function TermScreen:_close()
    self._term:onClose()
    if self._pty then
        pcall(function() self._pty:close() end)
    end
    UIManager:close(self)
end

function TermScreen:onClose()
    self:_close()
end

-- ── Physical keyboard passthrough ────────────────────────────────────────────

function TermScreen:onKeyPress(key)
    if self._term then
        return self._term:onKeyPress(key)
    end
end

-- ── Entry point ──────────────────────────────────────────────────────────────

function TermScreen:show()
    UIManager:show(self)
end

return TermScreen

--[[
    ui/termwidget.lua — KOReader widget that renders a VT100 grid.

    Sits inside TermScreen. Owns the VT100 emulator state and draws each
    cell as a glyph using Blitbuffer. On e-ink we skip per-cell colour
    rendering (greyscale only) and instead map SGR attributes to:
        bold        → heavier font face
        reverse     → invert fg/bg
        underline   → drawn as a 1px line below the cell baseline
        dim         → lighter grey
    On colour screens (determined by Screen:isColorEnabled()) we render
    fg/bg colors from the 16-colour ANSI palette mapped to greyscale ramps.

    Cursor is drawn as a blinking block via a UIManager scheduled task;
    on e-ink we use a static underline cursor instead to avoid flicker.
--]]

local Blitbuffer     = require("ffi/blitbuffer")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup  = require("ui/widget/verticalgroup")
local Font           = require("ui/font")
local Screen         = require("device/screen")
local UIManager      = require("ui/uimanager")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local logger         = require("logger")
local VT100          = require("plugins/inkterm/ui/vt100")

-- Monospace font faces
local FACE_NORMAL = Font:getFace("infont",  16)
local FACE_BOLD   = Font:getFace("infont",  16)  -- same; bold via blitbuffer
-- Cell dimensions derived from font metrics
local CELL_W = FACE_NORMAL:getSize().w or 10
local CELL_H = FACE_NORMAL:getSize().h or 18

-- ANSI 16-colour greyscale map (approximate luminance ordering)
local ANSI16_GREY = {
    [1]  = Blitbuffer.COLOR_BLACK,           -- black
    [2]  = Blitbuffer.gray(0.5),             -- dark red → 50% grey
    [3]  = Blitbuffer.gray(0.4),             -- dark green
    [4]  = Blitbuffer.gray(0.6),             -- dark yellow
    [5]  = Blitbuffer.gray(0.3),             -- dark blue
    [6]  = Blitbuffer.gray(0.5),             -- dark magenta
    [7]  = Blitbuffer.gray(0.5),             -- dark cyan
    [8]  = Blitbuffer.gray(0.75),            -- light grey
    [9]  = Blitbuffer.gray(0.4),             -- dark grey (bright black)
    [10] = Blitbuffer.gray(0.65),            -- bright red
    [11] = Blitbuffer.gray(0.55),            -- bright green
    [12] = Blitbuffer.gray(0.8),             -- bright yellow
    [13] = Blitbuffer.gray(0.45),            -- bright blue
    [14] = Blitbuffer.gray(0.7),             -- bright magenta
    [15] = Blitbuffer.gray(0.7),             -- bright cyan
    [16] = Blitbuffer.COLOR_WHITE,           -- white
}

local TermWidget = InputContainer:extend{
    name    = "TermWidget",
    is_y    = 0,
    is_x    = 0,
}

function TermWidget:init()
    self._vt  = VT100:new(self.cols or 80, self.rows or 24)
    self._pty = self.pty  -- set by TermScreen

    -- Pixel dimensions
    self.width  = self.width  or Screen:getWidth()
    self.height = self.height or (Screen:getHeight() - (self.kb_height or 0))

    -- Recompute cols/rows from actual pixel size
    self.cols = math.floor(self.width  / CELL_W)
    self.rows = math.floor(self.height / CELL_H)
    self._vt:resize(self.cols, self.rows)
    if self._pty then
        self._pty:resize(self.cols, self.rows)
    end

    self.dimen = Geom:new{ w = self.width, h = self.height }
    self._bb   = Blitbuffer.new(self.width, self.height, Screen:getFrameBufferColorDepth())
    self._bb:fill(Blitbuffer.COLOR_WHITE)

    -- Schedule read polling
    self._poll_action = function()
        self:_poll_pty()
        UIManager:scheduleIn(0.05, self._poll_action)
    end
    UIManager:scheduleIn(0.05, self._poll_action)

    -- Gesture input
    self.ges_events.TapGrid = {
        GestureRange:new{ ges = "tap", range = self.dimen }
    }
end

-- ── Rendering ────────────────────────────────────────────────────────────────

function TermWidget:_cell_rect(col, row)
    return Geom:new{
        x = (col - 1) * CELL_W,
        y = (row - 1) * CELL_H,
        w = CELL_W,
        h = CELL_H,
    }
end

function TermWidget:_attr_to_colors(attr)
    local fg = Blitbuffer.COLOR_BLACK
    local bg = Blitbuffer.COLOR_WHITE
    if attr.fg and attr.fg.idx then
        fg = ANSI16_GREY[attr.fg.idx] or fg
    end
    if attr.bg and attr.bg.idx then
        bg = ANSI16_GREY[attr.bg.idx] or bg
    end
    if attr.dim then
        fg = Blitbuffer.gray(0.55)
    end
    if attr.reverse then
        fg, bg = bg, fg
    end
    return fg, bg
end

function TermWidget:_render_grid()
    local vt    = self._vt
    local bb    = self._bb
    local cx    = vt.cursor_x
    local cy    = vt.cursor_y

    bb:fill(Blitbuffer.COLOR_WHITE)

    for r = 1, vt.rows do
        local grid_row = vt.grid[r]
        if grid_row then
            for c = 1, vt.cols do
                local cell = grid_row[c]
                if cell then
                    local rect = self:_cell_rect(c, r)
                    local attr  = cell.attr or {}
                    local fg, bg = self:_attr_to_colors(attr)

                    -- Background
                    if bg ~= Blitbuffer.COLOR_WHITE then
                        bb:paintRect(rect.x, rect.y, rect.w, rect.h, bg)
                    end

                    -- Glyph
                    if cell.ch and cell.ch ~= " " then
                        local face = attr.bold and FACE_BOLD or FACE_NORMAL
                        bb:drawText(cell.ch, face, rect.x, rect.y + CELL_H - 2, fg)
                    end

                    -- Underline
                    if attr.underline then
                        bb:paintRect(rect.x, rect.y + CELL_H - 2, rect.w, 1, fg)
                    end
                end
            end
        end
    end

    -- Cursor (underline style — no flicker on e-ink)
    local cr = self:_cell_rect(cx, cy)
    bb:paintRect(cr.x, cr.y + CELL_H - 2, CELL_W, 2, Blitbuffer.COLOR_BLACK)

    vt.dirty = false
end

function TermWidget:paintTo(bb, x, y)
    if self._vt.dirty then
        self:_render_grid()
    end
    bb:blitFrom(self._bb, x, y, 0, 0, self.width, self.height)
end

-- ── PTY polling ──────────────────────────────────────────────────────────────

function TermWidget:_poll_pty()
    if not self._pty then return end
    local data = self._pty:read()
    if data and #data > 0 then
        self._vt:feed(data)
        UIManager:setDirty(self, "partial")
    end
end

-- ── Input handling ───────────────────────────────────────────────────────────

function TermWidget:sendInput(str)
    if self._pty then
        self._pty:write(str)
    end
end

-- Physical keyboard key events
function TermWidget:onKeyPress(key)
    local kn = key.key
    -- Map KOReader key names to terminal sequences
    local KEY_MAP = {
        Up        = "\27[A",
        Down      = "\27[B",
        Right     = "\27[C",
        Left      = "\27[D",
        PageUp    = "\27[5~",
        PageDown  = "\27[6~",
        Home      = "\27[H",
        End       = "\27[F",
        Delete    = "\27[3~",
        Insert    = "\27[2~",
        F1        = "\27OP",
        F2        = "\27OQ",
        F3        = "\27OR",
        F4        = "\27OS",
        BackSpace = "\127",
        Return    = "\r",
        Tab       = "\t",
        Escape    = "\27",
    }
    -- Ctrl modifier
    if key.ctrl and kn and kn:match("^[a-zA-Z@%[%\\%]%^_]$") then
        local b = kn:upper():byte(1)
        if b >= 64 and b <= 95 then
            self:sendInput(string.char(b - 64))
            return true
        end
    end
    if KEY_MAP[kn] then
        self:sendInput(KEY_MAP[kn])
        return true
    end
    if kn and #kn == 1 then
        self:sendInput(kn)
        return true
    end
    return false
end

function TermWidget:onClose()
    UIManager:unschedule(self._poll_action)
end

return TermWidget

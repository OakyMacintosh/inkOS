--[[
    ui/vt100.lua — VT100/ANSI terminal emulator state machine.

    Maintains a 2-D grid of cells (char + SGR attributes).
    Does NOT do any rendering itself; the grid is consumed by TermWidget.

    Supported sequences:
        Cursor movement:    CUP, CUU, CUD, CUF, CUB, HVP, CHA, VPA
        Erase:              ED (0/1/2), EL (0/1/2)
        SGR:                bold, dim, underline, blink, reverse, fg/bg
                            colours (8-colour + 256-colour + 24-bit RGB)
        Scroll:             SU, SD, DECSTBM (scroll region)
        Misc:               RIS, DECSC/DECRC, SM/RM (wrap mode)
        C0:                 BEL, BS, HT (tab), LF/VT/FF, CR
        OSC:                title set (ignored, no window title on e-ink)
--]]

local VT100 = {}
VT100.__index = VT100

-- Default cell
local function blank_cell(attr)
    return { ch = " ", attr = attr or {} }
end

function VT100:new(cols, rows)
    local o = setmetatable({}, VT100)
    o.cols     = cols or 80
    o.rows     = rows or 24
    o.cursor_x = 1   -- 1-based
    o.cursor_y = 1
    o.scroll_top    = 1
    o.scroll_bottom = rows or 24
    o.wrap_mode     = true
    o.pending_wrap  = false  -- "deferred wrap" flag (VT100 quirk)
    o.saved_cursor  = { x = 1, y = 1 }
    o.cur_attr      = {}     -- current SGR attributes
    o._parse_buf    = ""     -- incomplete escape sequence buffer
    o._state        = "normal"
    o.dirty         = true
    o.title         = "inkOS Terminal"

    -- Allocate grid
    o.grid = {}
    for r = 1, o.rows do
        o.grid[r] = {}
        for c = 1, o.cols do
            o.grid[r][c] = blank_cell()
        end
    end

    return o
end

-- ── Internal helpers ─────────────────────────────────────────────────────────

function VT100:_cell(x, y)
    local row = self.grid[y]
    if not row then return nil end
    return row[x]
end

function VT100:_set_cell(x, y, ch, attr)
    local row = self.grid[y]
    if not row then return end
    if x < 1 or x > self.cols then return end
    row[x] = { ch = ch, attr = attr or self.cur_attr }
    self.dirty = true
end

function VT100:_scroll_up(n)
    n = n or 1
    local top = self.scroll_top
    local bot = self.scroll_bottom
    for _ = 1, n do
        table.remove(self.grid, top)
        local new_row = {}
        for c = 1, self.cols do new_row[c] = blank_cell() end
        table.insert(self.grid, bot, new_row)
    end
    self.dirty = true
end

function VT100:_scroll_down(n)
    n = n or 1
    local top = self.scroll_top
    local bot = self.scroll_bottom
    for _ = 1, n do
        table.remove(self.grid, bot)
        local new_row = {}
        for c = 1, self.cols do new_row[c] = blank_cell() end
        table.insert(self.grid, top, new_row)
    end
    self.dirty = true
end

function VT100:_erase_line(y, from, to)
    from = from or 1
    to   = to   or self.cols
    for c = from, to do
        self.grid[y][c] = blank_cell()
    end
    self.dirty = true
end

function VT100:_erase_screen(from_y, from_x, to_y, to_x)
    for r = from_y, to_y do
        local cf = (r == from_y) and from_x or 1
        local ct = (r == to_y)   and to_x   or self.cols
        for c = cf, ct do
            if self.grid[r] then
                self.grid[r][c] = blank_cell()
            end
        end
    end
    self.dirty = true
end

function VT100:_clamp_cursor()
    self.cursor_x = math.max(1, math.min(self.cols,     self.cursor_x))
    self.cursor_y = math.max(1, math.min(self.rows,     self.cursor_y))
end

function VT100:_newline()
    if self.cursor_y == self.scroll_bottom then
        self:_scroll_up(1)
    else
        self.cursor_y = self.cursor_y + 1
    end
    self.pending_wrap = false
end

-- ── SGR parser ───────────────────────────────────────────────────────────────

local SGR_FG = {
    [30]=1,[31]=2,[32]=3,[33]=4,[34]=5,[35]=6,[36]=7,[37]=8,
    [90]=9,[91]=10,[92]=11,[93]=12,[94]=13,[95]=14,[96]=15,[97]=16,
}
local SGR_BG = {
    [40]=1,[41]=2,[42]=3,[43]=4,[44]=5,[45]=6,[46]=7,[47]=8,
    [100]=9,[101]=10,[102]=11,[103]=12,[104]=13,[105]=14,[106]=15,[107]=16,
}

local function copy_attr(a)
    local n = {}
    for k, v in pairs(a) do n[k] = v end
    return n
end

function VT100:_apply_sgr(params)
    if #params == 0 then params = {0} end
    local i = 1
    while i <= #params do
        local p = params[i]
        if     p == 0  then self.cur_attr = {}
        elseif p == 1  then self.cur_attr = copy_attr(self.cur_attr); self.cur_attr.bold      = true
        elseif p == 2  then self.cur_attr = copy_attr(self.cur_attr); self.cur_attr.dim       = true
        elseif p == 4  then self.cur_attr = copy_attr(self.cur_attr); self.cur_attr.underline = true
        elseif p == 5  then self.cur_attr = copy_attr(self.cur_attr); self.cur_attr.blink     = true
        elseif p == 7  then self.cur_attr = copy_attr(self.cur_attr); self.cur_attr.reverse   = true
        elseif p == 22 then self.cur_attr = copy_attr(self.cur_attr); self.cur_attr.bold      = nil; self.cur_attr.dim = nil
        elseif p == 24 then self.cur_attr = copy_attr(self.cur_attr); self.cur_attr.underline = nil
        elseif p == 27 then self.cur_attr = copy_attr(self.cur_attr); self.cur_attr.reverse   = nil
        elseif p == 39 then self.cur_attr = copy_attr(self.cur_attr); self.cur_attr.fg        = nil
        elseif p == 49 then self.cur_attr = copy_attr(self.cur_attr); self.cur_attr.bg        = nil
        elseif SGR_FG[p] then
            self.cur_attr = copy_attr(self.cur_attr)
            self.cur_attr.fg = { idx = SGR_FG[p] }
        elseif SGR_BG[p] then
            self.cur_attr = copy_attr(self.cur_attr)
            self.cur_attr.bg = { idx = SGR_BG[p] }
        elseif p == 38 then
            self.cur_attr = copy_attr(self.cur_attr)
            if params[i+1] == 5 then
                self.cur_attr.fg = { idx256 = params[i+2] }
                i = i + 2
            elseif params[i+1] == 2 then
                self.cur_attr.fg = { r = params[i+2], g = params[i+3], b = params[i+4] }
                i = i + 4
            end
        elseif p == 48 then
            self.cur_attr = copy_attr(self.cur_attr)
            if params[i+1] == 5 then
                self.cur_attr.bg = { idx256 = params[i+2] }
                i = i + 2
            elseif params[i+1] == 2 then
                self.cur_attr.bg = { r = params[i+2], g = params[i+3], b = params[i+4] }
                i = i + 4
            end
        end
        i = i + 1
    end
end

-- ── CSI dispatcher ───────────────────────────────────────────────────────────

function VT100:_dispatch_csi(params_str, final)
    local params = {}
    for n in (params_str .. ";"):gmatch("([^;]*);") do
        params[#params+1] = tonumber(n) or 0
    end
    local function p(n) return params[n] or 0 end
    local function pp(n, default) return (params[n] and params[n] > 0) and params[n] or default end

    if     final == "H" or final == "f" then  -- CUP / HVP
        self.cursor_y = math.max(1, math.min(self.rows, pp(1,1)))
        self.cursor_x = math.max(1, math.min(self.cols, pp(2,1)))
        self.pending_wrap = false
    elseif final == "A" then self.cursor_y = math.max(1, self.cursor_y - pp(1,1)); self.pending_wrap = false
    elseif final == "B" then self.cursor_y = math.min(self.rows, self.cursor_y + pp(1,1)); self.pending_wrap = false
    elseif final == "C" then self.cursor_x = math.min(self.cols, self.cursor_x + pp(1,1)); self.pending_wrap = false
    elseif final == "D" then self.cursor_x = math.max(1, self.cursor_x - pp(1,1)); self.pending_wrap = false
    elseif final == "G" then self.cursor_x = math.max(1, math.min(self.cols, pp(1,1))); self.pending_wrap = false
    elseif final == "d" then self.cursor_y = math.max(1, math.min(self.rows, pp(1,1))); self.pending_wrap = false
    elseif final == "J" then
        local n = p(1)
        if     n == 0 then self:_erase_screen(self.cursor_y, self.cursor_x, self.rows, self.cols)
        elseif n == 1 then self:_erase_screen(1, 1, self.cursor_y, self.cursor_x)
        elseif n == 2 then self:_erase_screen(1, 1, self.rows, self.cols)
        end
    elseif final == "K" then
        local n = p(1)
        if     n == 0 then self:_erase_line(self.cursor_y, self.cursor_x, self.cols)
        elseif n == 1 then self:_erase_line(self.cursor_y, 1, self.cursor_x)
        elseif n == 2 then self:_erase_line(self.cursor_y)
        end
    elseif final == "m" then self:_apply_sgr(params)
    elseif final == "S" then self:_scroll_up(pp(1,1))
    elseif final == "T" then self:_scroll_down(pp(1,1))
    elseif final == "r" then  -- DECSTBM
        self.scroll_top    = math.max(1, pp(1,1))
        self.scroll_bottom = math.min(self.rows, pp(2, self.rows))
        if self.scroll_top >= self.scroll_bottom then
            self.scroll_top    = 1
            self.scroll_bottom = self.rows
        end
    elseif final == "s" then  -- DECSC (also ?s)
        self.saved_cursor = { x = self.cursor_x, y = self.cursor_y }
    elseif final == "u" then  -- DECRC
        self.cursor_x = self.saved_cursor.x
        self.cursor_y = self.saved_cursor.y
    elseif final == "h" or final == "l" then
        -- SM / RM — only handle ?7 (DECAWM wrap mode)
        if params_str:sub(1,1) == "?" then
            local mode = pp(1,0)
            if mode == 7 then
                self.wrap_mode = (final == "h")
            end
        end
    elseif final == "@" then  -- ICH — insert blank characters
        local n = pp(1,1)
        local row = self.grid[self.cursor_y]
        for _ = 1, n do
            table.remove(row, self.cols)
            table.insert(row, self.cursor_x, blank_cell())
        end
        self.dirty = true
    elseif final == "P" then  -- DCH — delete characters
        local n = pp(1,1)
        local row = self.grid[self.cursor_y]
        for _ = 1, n do
            table.remove(row, self.cursor_x)
            table.insert(row, blank_cell())
        end
        self.dirty = true
    end
end

-- ── Public: feed raw bytes ───────────────────────────────────────────────────

function VT100:feed(data)
    local buf = self._parse_buf .. data
    self._parse_buf = ""
    local i = 1
    local len = #buf

    while i <= len do
        local byte = buf:byte(i)

        -- ── C0 control characters ──
        if byte == 7 then       -- BEL
            i = i + 1
        elseif byte == 8 then   -- BS
            if self.cursor_x > 1 then self.cursor_x = self.cursor_x - 1 end
            self.pending_wrap = false
            i = i + 1
        elseif byte == 9 then   -- HT (tab)
            local next_tab = math.floor((self.cursor_x - 1) / 8) * 8 + 9
            self.cursor_x = math.min(next_tab, self.cols)
            i = i + 1
        elseif byte == 10 or byte == 11 or byte == 12 then  -- LF / VT / FF
            self:_newline()
            i = i + 1
        elseif byte == 13 then  -- CR
            self.cursor_x    = 1
            self.pending_wrap = false
            i = i + 1

        -- ── ESC sequences ──
        elseif byte == 27 then  -- ESC
            if i + 1 > len then
                -- Incomplete — save for next feed
                self._parse_buf = buf:sub(i)
                return
            end
            local next = buf:byte(i + 1)

            if next == 91 then   -- ESC [ → CSI
                -- Find end of CSI sequence
                local j = i + 2
                local params_start = j
                -- Parameter bytes: 0x30–0x3F
                while j <= len and buf:byte(j) >= 0x30 and buf:byte(j) <= 0x3F do
                    j = j + 1
                end
                -- Intermediate bytes: 0x20–0x2F
                while j <= len and buf:byte(j) >= 0x20 and buf:byte(j) <= 0x2F do
                    j = j + 1
                end
                if j > len then
                    self._parse_buf = buf:sub(i)
                    return
                end
                local final      = buf:sub(j, j)
                local params_str = buf:sub(params_start, j - 1)
                self:_dispatch_csi(params_str, final)
                i = j + 1

            elseif next == 93 then  -- ESC ] → OSC (consume until ST or BEL)
                local j = i + 2
                while j <= len do
                    local b = buf:byte(j)
                    if b == 7 then j = j + 1; break end  -- BEL terminator
                    if b == 27 and j + 1 <= len and buf:byte(j+1) == 92 then
                        j = j + 2; break  -- ST terminator
                    end
                    j = j + 1
                end
                if j > len + 1 then
                    self._parse_buf = buf:sub(i)
                    return
                end
                i = j  -- consumed

            elseif next == 55 then  -- ESC 7 — DECSC
                self.saved_cursor = { x = self.cursor_x, y = self.cursor_y }
                i = i + 2
            elseif next == 56 then  -- ESC 8 — DECRC
                self.cursor_x = self.saved_cursor.x
                self.cursor_y = self.saved_cursor.y
                i = i + 2
            elseif next == 99 then  -- ESC c — RIS
                self:reset()
                i = i + 2
            elseif next == 77 then  -- ESC M — reverse index
                if self.cursor_y == self.scroll_top then
                    self:_scroll_down(1)
                else
                    self.cursor_y = self.cursor_y - 1
                end
                i = i + 2
            else
                i = i + 2  -- unknown 2-byte ESC sequence, skip
            end

        -- ── Printable UTF-8 ──
        else
            -- Determine UTF-8 character byte length
            local char_len
            if     byte < 0x80 then char_len = 1
            elseif byte < 0xC0 then char_len = 1   -- continuation byte (error) → skip
            elseif byte < 0xE0 then char_len = 2
            elseif byte < 0xF0 then char_len = 3
            else                    char_len = 4
            end

            if i + char_len - 1 > len then
                self._parse_buf = buf:sub(i)
                return
            end

            local ch = buf:sub(i, i + char_len - 1)

            -- Deferred wrap (VT100 last-column behaviour)
            if self.pending_wrap and self.wrap_mode then
                self.cursor_x = 1
                self:_newline()
            end
            self.pending_wrap = false

            self:_set_cell(self.cursor_x, self.cursor_y, ch, self.cur_attr)

            if self.cursor_x >= self.cols then
                self.pending_wrap = true
            else
                self.cursor_x = self.cursor_x + 1
            end

            i = i + char_len
        end
    end
end

-- ── Resize ───────────────────────────────────────────────────────────────────

function VT100:resize(cols, rows)
    -- Expand or trim columns
    for r = 1, #self.grid do
        local row = self.grid[r]
        while #row < cols do row[#row+1] = blank_cell() end
        while #row > cols do row[#row]   = nil end
    end
    -- Expand or trim rows
    while #self.grid < rows do
        local new_row = {}
        for c = 1, cols do new_row[c] = blank_cell() end
        self.grid[#self.grid+1] = new_row
    end
    while #self.grid > rows do
        self.grid[#self.grid] = nil
    end

    self.cols = cols
    self.rows = rows
    self.scroll_top    = 1
    self.scroll_bottom = rows
    self:_clamp_cursor()
    self.dirty = true
end

function VT100:reset()
    self.cursor_x       = 1
    self.cursor_y       = 1
    self.scroll_top     = 1
    self.scroll_bottom  = self.rows
    self.wrap_mode      = true
    self.pending_wrap   = false
    self.cur_attr       = {}
    self.saved_cursor   = { x = 1, y = 1 }
    self._parse_buf     = ""
    for r = 1, self.rows do
        for c = 1, self.cols do
            self.grid[r][c] = blank_cell()
        end
    end
    self.dirty = true
end

return VT100

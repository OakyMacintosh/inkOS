--[[
    pty/busybox_pty.lua — pipe-based pseudo-terminal for Kindle and Kobo.

    These devices run a stripped Linux with busybox. /dev/ptmx often exists
    but may not be accessible without root. This backend uses popen-style
    bidirectional pipes through a small wrapper script instead.

    Limitations vs a real PTY:
        - No SIGWINCH / terminal resize signalling to the child shell
        - No raw-mode input (the shell always sees line-buffered stdin)
        - Job control (Ctrl-C, Ctrl-Z) sent as escape sequences manually
        - No true in-band terminal size negotiation (we fake COLUMNS/LINES
          via env vars)

    Approach:
        We open a shell with io.popen for reading and a separate mkfifo-based
        pipe for writing, connected via:
            mkfifo /tmp/inkterm_in
            sh < /tmp/inkterm_in &
            cat /tmp/inkterm_in  ← our write fd
        Output is read from the shell's stdout/stderr merged via "2>&1".

    API: same as linux_pty.lua
--]]

local logger = require("logger")

-- Try to find a usable shell
local SHELLS = {
    "/bin/sh", "/bin/bash", "/usr/bin/sh",
    -- Kindle
    "/bin/msh",
    -- Kobo
    "/bin/ash",
}

local BusyboxPty = {}
BusyboxPty.__index = BusyboxPty

local FIFO_PATH = "/tmp/inkterm_in_" .. tostring(os.time())

local function find_shell()
    for _, sh in ipairs(SHELLS) do
        local f = io.open(sh, "r")
        if f then f:close() return sh end
    end
    return nil
end

function BusyboxPty:open(cols, rows)
    self._cols = cols or 80
    self._rows = rows or 24

    local shell = find_shell()
    if not shell then
        return false, "no usable shell found on this device"
    end
    self._shell = shell

    -- Create the input FIFO
    local ret = os.execute("mkfifo " .. FIFO_PATH .. " 2>/dev/null")
    if ret ~= 0 then
        -- Some devices have no mkfifo; fall back to a regular temp file
        -- (write-then-read, very limited but better than nothing)
        logger.warn("inkterm(busybox): mkfifo failed, using temp file fallback")
        self._fifo_path = nil
    else
        self._fifo_path = FIFO_PATH
    end

    -- Set COLUMNS and LINES so the shell and its children see our dimensions
    local env = string.format(
        "TERM=vt100 COLUMNS=%d LINES=%d HOME=%s PATH=%s",
        cols, rows,
        os.getenv("HOME") or "/tmp",
        os.getenv("PATH") or "/bin:/usr/bin:/sbin"
    )

    local cmd
    if self._fifo_path then
        -- Launch shell reading from fifo, writing to a temp output file
        self._out_path = "/tmp/inkterm_out_" .. tostring(os.time())
        cmd = string.format(
            "%s %s %s < %s > %s 2>&1 &",
            env, shell, "-i", self._fifo_path, self._out_path
        )
        os.execute(cmd)
        -- Open write end of fifo
        self._write_f = io.open(self._fifo_path, "w")
        if not self._write_f then
            return false, "could not open input FIFO for writing"
        end
        self._write_f:setvbuf("no")  -- unbuffered
        -- Open read end of output file (tail-style)
        self._read_f = io.open(self._out_path, "r")
        if not self._read_f then
            return false, "could not open output file for reading"
        end
    else
        -- Simplest fallback: popen a shell, send commands line by line
        -- (read-only; writes go to a queue flushed via /proc/self/fd tricks)
        self._popen_f = io.popen(
            string.format("%s %s -i 2>&1", env, shell), "r"
        )
        if not self._popen_f then
            return false, "io.popen failed"
        end
    end

    self._write_queue = {}
    logger.info("inkterm(busybox): shell started:", shell)
    return true
end

function BusyboxPty:write(data)
    if self._write_f then
        self._write_f:write(data)
        self._write_f:flush()
    elseif self._popen_f then
        -- Can't write back to a popen handle in read mode;
        -- queue it for a workaround (limited functionality)
        table.insert(self._write_queue, data)
        logger.warn("inkterm(busybox): write to popen not supported — queued")
    end
end

function BusyboxPty:read()
    if self._read_f then
        local chunk = self._read_f:read(4096)
        return chunk  -- nil if nothing yet
    elseif self._popen_f then
        -- Non-blocking read attempt via select would need FFI;
        -- do a single line read (blocking — acceptable for line-mode)
        local line = self._popen_f:read("*l")
        if line then return line .. "\n" end
    end
    return nil
end

function BusyboxPty:resize(cols, rows)
    -- No TIOCSWINSZ without a real PTY; update env vars by sending
    -- the shell a command that re-exports COLUMNS/LINES
    self._cols = cols
    self._rows = rows
    self:write(string.format("export COLUMNS=%d LINES=%d\n", cols, rows))
end

function BusyboxPty:close()
    self:write("exit\n")
    if self._write_f then
        pcall(function() self._write_f:close() end)
        self._write_f = nil
    end
    if self._read_f then
        pcall(function() self._read_f:close() end)
        self._read_f = nil
    end
    if self._popen_f then
        pcall(function() self._popen_f:close() end)
        self._popen_f = nil
    end
    -- Cleanup temp files
    if self._fifo_path then
        os.execute("rm -f " .. self._fifo_path)
    end
    if self._out_path then
        os.execute("rm -f " .. self._out_path)
    end
end

function BusyboxPty:new()
    return setmetatable({}, BusyboxPty)
end

return BusyboxPty

--[[
    pty/linux_pty.lua — forkpty(3) backend for Linux/desktop KOReader
    and any embedded Linux with a working /dev/ptmx.

    Uses LuaJIT FFI to call forkpty() from libutil (glibc) or libutil.so.1.
    Falls back to openpty() + fork() manually if forkpty is not found.

    API (shared by all backends):
        backend:open(cols, rows)  → true/err
        backend:write(data)
        backend:read()            → string or nil
        backend:resize(cols, rows)
        backend:close()
        backend.on_data           = function(data) end  (set by caller)
--]]

local ffi = require("ffi")
local bit = require("bit")
local logger = require("logger")

ffi.cdef[[
    /* termios / winsize */
    struct winsize {
        unsigned short ws_row;
        unsigned short ws_col;
        unsigned short ws_xpixel;
        unsigned short ws_ypixel;
    };

    /* forkpty */
    int forkpty(int *amaster, char *name, void *termp, struct winsize *winp);

    /* openpty (fallback) */
    int openpty(int *amaster, int *aslave, char *name,
                void *termp, struct winsize *winp);

    /* POSIX */
    pid_t fork(void);
    int   execl(const char *path, const char *arg, ...);
    int   close(int fd);
    int   ioctl(int fd, unsigned long request, ...);
    pid_t waitpid(pid_t pid, int *status, int options);
    int   kill(pid_t pid, int sig);

    /* non-blocking read */
    typedef int ssize_t;
    ssize_t read(int fd, void *buf, size_t count);
    ssize_t write(int fd, const void *buf, size_t count);

    /* fcntl for O_NONBLOCK */
    int fcntl(int fd, int cmd, ...);
]]

local TIOCSWINSZ = 0x5414  -- Linux x86/ARM
local F_SETFL    = 4
local O_NONBLOCK = 2048
local SIGTERM    = 15
local SIGKILL    = 9
local WNOHANG    = 1

-- Try loading libutil; on musl (Kobo/Kindle transplant) it may be in libc
local libutil
do
    local libs = { "libutil.so.1", "libutil.so", "libc.so.6", "libc.so" }
    for _, l in ipairs(libs) do
        local ok, lib = pcall(ffi.load, l)
        if ok then
            -- Confirm forkpty is actually in this lib
            local sym_ok = pcall(function()
                return lib.forkpty
            end)
            if sym_ok then
                libutil = lib
                logger.info("inkterm: loaded forkpty from", l)
                break
            end
        end
    end
end

local LinuxPty = {}
LinuxPty.__index = LinuxPty

function LinuxPty:open(cols, rows)
    if not libutil then
        return false, "forkpty not available on this system"
    end

    local winp = ffi.new("struct winsize")
    winp.ws_col = cols or 80
    winp.ws_row = rows or 24

    local master_fd = ffi.new("int[1]")
    local pid = libutil.forkpty(master_fd, nil, nil, winp)

    if pid < 0 then
        return false, "forkpty() failed: " .. tostring(ffi.errno())
    end

    if pid == 0 then
        -- Child: exec the shell
        local shell = os.getenv("SHELL") or "/bin/sh"
        -- Try bash, then sh
        local shells = { shell, "/bin/bash", "/bin/sh", "/usr/bin/sh" }
        for _, sh in ipairs(shells) do
            ffi.C.execl(sh, sh, nil)
        end
        -- If we reach here, exec failed — exit child
        os.exit(1)
    end

    -- Parent
    self._master_fd = master_fd[0]
    self._pid       = pid

    -- Set master fd non-blocking
    ffi.C.fcntl(self._master_fd, F_SETFL, O_NONBLOCK)

    self._buf = ffi.new("uint8_t[4096]")
    return true
end

function LinuxPty:write(data)
    if not self._master_fd then return end
    ffi.C.write(self._master_fd, data, #data)
end

function LinuxPty:read()
    if not self._master_fd then return nil end
    local n = ffi.C.read(self._master_fd, self._buf, 4096)
    if n > 0 then
        return ffi.string(self._buf, n)
    end
    return nil
end

function LinuxPty:resize(cols, rows)
    if not self._master_fd then return end
    local winp = ffi.new("struct winsize")
    winp.ws_col = cols
    winp.ws_row = rows
    ffi.C.ioctl(self._master_fd, TIOCSWINSZ, winp)
end

function LinuxPty:close()
    if self._pid then
        ffi.C.kill(self._pid, SIGTERM)
        -- Give it a moment then SIGKILL
        local status = ffi.new("int[1]")
        for _ = 1, 5 do
            local r = ffi.C.waitpid(self._pid, status, WNOHANG)
            if r ~= 0 then break end
            -- Busy-wait 100ms equivalent (LuaJIT has no sleep, use os.execute)
            os.execute("sleep 0.1")
        end
        ffi.C.kill(self._pid, SIGKILL)
        ffi.C.waitpid(self._pid, status, 0)
        self._pid = nil
    end
    if self._master_fd then
        ffi.C.close(self._master_fd)
        self._master_fd = nil
    end
end

function LinuxPty:new()
    return setmetatable({}, LinuxPty)
end

return LinuxPty

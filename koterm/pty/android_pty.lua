--[[
    pty/android_pty.lua — PTY backend for rooted Android.

    Android uses Bionic libc rather than glibc. forkpty() is available in
    libutil on some Android versions, but on others (especially older AOSP)
    it lives directly in libc.so. We also handle the Android-specific
    /dev/ptmx path and the fact that TIOCSWINSZ differs on ARM vs ARM64.

    Requires: root (CAP_SYS_ADMIN or just open /dev/ptmx as root),
              /system/bin/sh or /bin/sh in PATH.

    API: same as linux_pty.lua
--]]

local ffi = require("ffi")
local logger = require("logger")

ffi.cdef[[
    struct winsize {
        unsigned short ws_row;
        unsigned short ws_col;
        unsigned short ws_xpixel;
        unsigned short ws_ypixel;
    };

    int  forkpty(int *amaster, char *name, void *termp, struct winsize *winp);
    int  close(int fd);
    int  ioctl(int fd, unsigned long request, ...);
    pid_t waitpid(pid_t pid, int *status, int options);
    int  kill(pid_t pid, int sig);

    typedef int ssize_t;
    ssize_t read(int fd, void *buf, size_t count);
    ssize_t write(int fd, const void *buf, size_t count);
    int     fcntl(int fd, int cmd, ...);
    int     execl(const char *path, const char *arg, ...);
]]

-- TIOCSWINSZ: ARM/ARM64 Linux uses 0x5414
local TIOCSWINSZ = 0x5414
local F_SETFL    = 4
local O_NONBLOCK = 2048
local SIGTERM    = 15
local SIGKILL    = 9
local WNOHANG    = 1

-- Bionic may have forkpty in libc directly or in libutil
local libutil
do
    local candidates = {
        "libutil.so", "libutil.so.1",
        "/system/lib64/libc.so", "/system/lib/libc.so",
        "libc.so",
    }
    for _, l in ipairs(candidates) do
        local ok, lib = pcall(ffi.load, l)
        if ok then
            local has = pcall(function() return lib.forkpty end)
            if has then
                libutil = lib
                logger.info("inkterm(android): forkpty from", l)
                break
            end
        end
    end
end

local AndroidPty = {}
AndroidPty.__index = AndroidPty

local ANDROID_SHELLS = {
    "/system/bin/sh",
    "/system/bin/bash",
    "/bin/sh",
    "/sbin/sh",
}

function AndroidPty:open(cols, rows)
    if not libutil then
        return false, "forkpty not found in Bionic libc"
    end

    local winp = ffi.new("struct winsize")
    winp.ws_col = cols or 80
    winp.ws_row = rows or 24

    local master_fd = ffi.new("int[1]")
    local pid = libutil.forkpty(master_fd, nil, nil, winp)

    if pid < 0 then
        return false, "forkpty() failed errno=" .. tostring(ffi.errno())
    end

    if pid == 0 then
        -- Child: find and exec a shell
        -- Set a minimal environment for Android
        os.execute("export HOME=/data/local/tmp PATH=/system/bin:/bin:/sbin:$PATH")
        for _, sh in ipairs(ANDROID_SHELLS) do
            ffi.C.execl(sh, sh, nil)
        end
        os.exit(1)
    end

    self._master_fd = master_fd[0]
    self._pid       = pid
    ffi.C.fcntl(self._master_fd, F_SETFL, O_NONBLOCK)
    self._buf = ffi.new("uint8_t[4096]")
    return true
end

function AndroidPty:write(data)
    if not self._master_fd then return end
    ffi.C.write(self._master_fd, data, #data)
end

function AndroidPty:read()
    if not self._master_fd then return nil end
    local n = ffi.C.read(self._master_fd, self._buf, 4096)
    if n > 0 then return ffi.string(self._buf, n) end
    return nil
end

function AndroidPty:resize(cols, rows)
    if not self._master_fd then return end
    local winp = ffi.new("struct winsize")
    winp.ws_col = cols
    winp.ws_row = rows
    ffi.C.ioctl(self._master_fd, TIOCSWINSZ, winp)
end

function AndroidPty:close()
    if self._pid then
        ffi.C.kill(self._pid, SIGTERM)
        os.execute("sleep 0.15")
        local status = ffi.new("int[1]")
        ffi.C.waitpid(self._pid, status, WNOHANG)
        ffi.C.kill(self._pid, SIGKILL)
        ffi.C.waitpid(self._pid, status, 0)
        self._pid = nil
    end
    if self._master_fd then
        ffi.C.close(self._master_fd)
        self._master_fd = nil
    end
end

function AndroidPty:new()
    return setmetatable({}, AndroidPty)
end

return AndroidPty

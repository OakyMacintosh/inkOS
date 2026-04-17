--[[
    pty/init.lua — platform detection and PTY backend loader

    Supported backends:
        linux_pty    — forkpty(3) via LuaJIT FFI, for desktop/Debian KOReader
        android_pty  — forkpty via FFI under Android root (no Termux required)
        busybox_pty  — pipe-based fallback via busybox sh, for Kindle/Kobo
                       (these devices may lack a usable /dev/ptmx)

    Selection priority:
        1. Explicit override: PTY_BACKEND env var
        2. Android root detected (/proc/version contains "android", uid == 0
           or /dev/ptmx writable)
        3. /dev/ptmx accessible → linux_pty (covers desktop + Kobo/Kindle
           kernels that do expose ptmx)
        4. Fallback → busybox_pty
--]]

local ffi = require("ffi")
local util = require("util")
local logger = require("logger")

local PtyBackend = {}

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local s = f:read("*a")
    f:close()
    return s or ""
end

local function is_android()
    local ver = read_file("/proc/version"):lower()
    return ver:find("android") ~= nil
end

local function ptmx_accessible()
    -- Try opening /dev/ptmx for write; root required on most embedded Linux
    local f = io.open("/dev/ptmx", "w")
    if f then f:close() return true end
    return false
end

local function detect_backend()
    local override = os.getenv("INKTERM_PTY_BACKEND")
    if override then
        logger.info("inkterm: PTY backend override:", override)
        return override
    end

    if is_android() then
        -- On Android we always try the native PTY first (requires root).
        -- If /dev/ptmx is missing we fall through to busybox.
        if ptmx_accessible() then
            logger.info("inkterm: Android root PTY detected")
            return "android_pty"
        else
            logger.info("inkterm: Android without ptmx, falling back to busybox")
            return "busybox_pty"
        end
    end

    if ptmx_accessible() then
        logger.info("inkterm: linux PTY detected")
        return "linux_pty"
    end

    logger.info("inkterm: no PTY device, using busybox pipe backend")
    return "busybox_pty"
end

function PtyBackend:new()
    local name = detect_backend()
    local ok, backend = pcall(require, "plugins/inkterm/pty/" .. name)
    if not ok then
        logger.warn("inkterm: failed to load backend", name, ":", backend)
        -- Last-ditch: busybox pipes almost always work
        backend = require("plugins/inkterm/pty/busybox_pty")
    end
    return backend
end

return PtyBackend

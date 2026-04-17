--[[
    main.lua — inkterm KOReader plugin entry point.

    Registers the plugin with KOReader and adds a "Terminal" entry to the
    main menu (Tools section) and to the file browser's context menu.
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local logger          = require("logger")
local _               = require("gettext")

local TermScreen      = require("plugins/inkterm/ui/termscreen")

local InkTerm = WidgetContainer:extend{
    name     = "inkterm",
    is_doc_plugin = false,
}

-- ── Menu items ───────────────────────────────────────────────────────────────

function InkTerm:addToMainMenu(menu_items)
    menu_items.inkterm = {
        text     = _("Terminal"),
        sorting_hint = "tools",
        callback = function()
            self:_openTerminal()
        end,
    }
end

-- ── Open terminal ────────────────────────────────────────────────────────────

function InkTerm:_openTerminal()
    local ok, TermScreenClass = pcall(require, "plugins/inkterm/ui/termscreen")
    if not ok then
        logger.err("inkterm: failed to load TermScreen:", TermScreenClass)
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = _("inkterm: failed to load terminal.\nSee log for details."),
        })
        return
    end

    local screen = TermScreenClass:new{}
    screen:show()
end

-- ── Plugin lifecycle ─────────────────────────────────────────────────────────

function InkTerm:onStart()
    logger.info("inkterm: plugin loaded")
end

function InkTerm:onExit()
    logger.info("inkterm: plugin exit")
end

return InkTerm

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local Screen = require("device/screen")
local Font = require("ui/font")
local _ = require("gettext")

local AboutDialog = {}

function AboutDialog:show()
    local w = Screen:getWidth()
    local h = Screen:getHeight()

    local face_title  = Font:getFace("tfont", 22)
    local face_sub    = Font:getFace("tfont", 14)
    local face_body   = Font:getFace("cfont", 15)
    local face_small  = Font:getFace("cfont", 13)

    local dialog_w = math.floor(w * 0.85)

    local title_widget = TextWidget:new{
        text = _("inkOS"),
        face = face_title,
        bold = true,
    }

    local version_widget = TextWidget:new{
        text = _("SimpleUI · version 1.0"),
        face = face_sub,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local sep = FrameContainer:new{
        margin  = 0,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        width  = dialog_w - 40,
        height = 1,
    }

    local desc_widget = TextBoxWidget:new{
        text = _(
            "inkOS is a cross thing OS that works on the dumbest things ever." ..
            "SimpleUI strips away complexity so you can focus entirely on the page."
        ),
        face  = face_body,
        width = dialog_w - 40,
    }

    local info_widget = TextBoxWidget:new{
        text = _(
            "Built on KOReader · open source · MIT license\n" ..
            "https://github.com/koreader/koreader"
        ),
        face  = face_small,
        width = dialog_w - 40,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local content = VerticalGroup:new{
        align = "center",
        title_widget,
        TextWidget:new{ text = "", face = face_small },  -- spacer
        version_widget,
        TextWidget:new{ text = "", face = face_small },  -- spacer
        sep,
        TextWidget:new{ text = "", face = face_small },  -- spacer
        desc_widget,
        TextWidget:new{ text = "", face = face_small },  -- spacer
        info_widget,
    }

    local framed = FrameContainer:new{
        padding    = 20,
        bordersize = 1,
        background = Blitbuffer.COLOR_WHITE,
        radius     = 8,
        content,
    }

    local centered = CenterContainer:new{
        dimen = Screen:getSize(),
        framed,
    }

    UIManager:show(ButtonDialog:new{
        title        = nil,
        buttons      = {
            {
                {
                    text    = _("Close"),
                    callback = function()
                        UIManager:close(self._dialog)
                    end,
                },
            },
        },
        anchor_view  = centered,
    })
end

return AboutDialog

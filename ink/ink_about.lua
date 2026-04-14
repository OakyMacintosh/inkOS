local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomContainer = require("ui/widget/container/geocontainer")
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
	local face_title = Font:getFace("tfont", 22)

end

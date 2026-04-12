function Terminal:init()
	self.ui.menu:registerToMainMenu(self)
end

function Terminal:addToMainMenu(menu_items)
	menu_items.terminal = {
		text = "Terminal",
		callback = function()
			self:showTerminal()
		end,
	}
end

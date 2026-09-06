--!strict
-- Speedtest Meter — bar widget entry point.
--
-- Shows a text/glyph in the bar; clicking it toggles the speedtest panel.
-- The displayed text is configurable from the panel (idle screen -> "Widget
-- icon" field) and shared across entries via noctalia.state, so it updates
-- live without needing to reload the plugin.

local DEFAULT_ICON = "SPD"
local currentIcon = DEFAULT_ICON
local watching = false

local function applyIcon(value: string?)
	if value and value ~= "" then
		currentIcon = value
	else
		currentIcon = DEFAULT_ICON
	end
	barWidget.setText(currentIcon)
end

function update()
	if not watching then
		watching = true
		applyIcon(noctalia.state.get("widgetIcon"))
		noctalia.state.watch("widgetIcon", function(value)
			applyIcon(value)
		end)
	end

	barWidget.setTooltip(noctalia.tr("widget_tooltip"))
end

function onClick()
	noctalia.togglePanel("nilsonlinux/speedtest-meter:speedtest")
end

--!strict
-- Speedtest Meter — bar widget entry point.
--
-- Shows a fixed label in the bar; clicking it toggles the speedtest panel.
--
-- No custom icon-customization logic here on purpose: overriding a bar
-- widget's label/icon per instance is something Noctalia itself already
-- handles for widgets in general (its own widget settings screen), not
-- something each plugin should reimplement. If your Noctalia version
-- exposes that natively for plugin widgets, use it there; if it doesn't yet
-- support custom icons for third-party widgets, let me know exactly where
-- that setting lives (or its config schema) and this can wire into it
-- properly instead of guessing again.

function update()
	barWidget.setText("SPD")
	barWidget.setTooltip(noctalia.tr("widget_tooltip"))
end

function onClick()
	noctalia.togglePanel("nilsonlinux/speedtest-meter:speedtest")
end

-- Hyprland 0.57 with its effects on (rounding, shadows, blur, animations)
-- for GPU runs on the iPad: hyprland-test.lua with nothing disabled but
-- the logo and splash; two foot windows so blur and shadows have
-- something behind them
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 2 })
hl.config({
    general = { gaps_in = 5, gaps_out = 20, border_size = 2 },
    decoration = {
        rounding = 10,
        active_opacity = 0.9,
        inactive_opacity = 0.8,
        shadow = { enabled = true, range = 8, render_power = 3 },
        blur = { enabled = true, size = 3, passes = 1 },
    },
    animations = { enabled = true },
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        background_color = 0xff336699,
    },
})
hl.on("hyprland.start", function ()
    hl.exec_cmd("foot")
    hl.exec_cmd("foot")
end)

-- Minimal Hyprland 0.57 configuration for GPU bring-up runs on the iPad:
-- no blur, shadows or animations, a distinctive background, one foot window
-- scale 2: the 1536x2048 panel at 264 ppi is a 2x display, as on iPadOS
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 2 })
hl.config({
    general = { gaps_in = 5, gaps_out = 20, border_size = 2 },
    decoration = {
        rounding = 0,
        shadow = { enabled = false },
        blur = { enabled = false },
    },
    animations = { enabled = false },
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        background_color = 0xff336699,
    },
})
hl.on("hyprland.start", function ()
    hl.exec_cmd("foot")
end)

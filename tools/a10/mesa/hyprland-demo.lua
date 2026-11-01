-- Hyprland 0.57 effects demo on the iPad (hypr-demo.sh): strong blur,
-- translucent windows, large shadows, rounded corners, a gradient border and
-- Hyprland's default animations, over demo-wallpaper.py's wallpaper. Hyprland
-- 0.57 blurs only behind surfaces that ask for it (ext-background-effect):
-- foot does with colors-dark.blur=yes
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 2 })
hl.config({
    general = {
        gaps_in = 4,
        gaps_out = 8,
        border_size = 3,
        col = {
            active_border = { colors = { "rgba(ff4f8bee)", "rgba(3cc8ffee)" }, angle = 45 },
            inactive_border = "rgba(ffffff40)",
        },
        layout = "dwindle",
    },
    decoration = {
        rounding = 18,
        rounding_power = 2,
        active_opacity = 1.0,
        inactive_opacity = 0.9,
        shadow = { enabled = true, range = 30, render_power = 3, color = 0xcc000000 },
        blur = { enabled = true, size = 8, passes = 3, vibrancy = 0.17 },
    },
    animations = { enabled = true },
    misc = {
        disable_hyprland_logo = false, -- draws wall0.png
        disable_splash_rendering = true,
        disable_hyprland_guiutils_check = true,
        disable_watchdog_warning = true,
    },
})
hl.curve("easeOutQuint", { type = "bezier", points = { {0.23, 1}, {0.32, 1} } })
hl.curve("almostLinear", { type = "bezier", points = { {0.5, 0.5}, {0.75, 1} } })
hl.curve("linear",       { type = "bezier", points = { {0, 0}, {1, 1} } })
hl.curve("quick",        { type = "bezier", points = { {0.15, 0}, {0.1, 1} } })
hl.curve("easy",         { type = "spring", mass = 1, stiffness = 238.1191, damping = 24.21279333 })
hl.animation({ leaf = "global",       enabled = true, speed = 10,   bezier = "default" })
hl.animation({ leaf = "border",       enabled = true, speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "borderangle",  enabled = true, speed = 40,   bezier = "linear", style = "loop" })
hl.animation({ leaf = "windows",      enabled = true, speed = 4.79, spring = "easy" })
hl.animation({ leaf = "windowsIn",    enabled = true, speed = 4.1,  spring = "easy", style = "popin 87%" })
hl.animation({ leaf = "windowsOut",   enabled = true, speed = 1.49, bezier = "linear", style = "popin 87%" })
hl.animation({ leaf = "fade",         enabled = true, speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "workspaces",   enabled = true, speed = 3,    bezier = "easeOutQuint", style = "slidevert" })
hl.on("hyprland.start", function ()
    hl.exec_cmd("foot -o colors-dark.alpha=0.45 -o colors-dark.blur=yes sh /root/demo-term.sh info")
    hl.exec_cmd("foot -o colors-dark.alpha=0.45 -o colors-dark.blur=yes sh /root/demo-term.sh palette")
    hl.exec_cmd("foot -o colors-dark.alpha=0.45 -o colors-dark.blur=yes sh /root/demo-term.sh clock")
end)

-- Omarchy's look with its Jade Horse theme and glassy windows, for the
-- iPad demo (hypr-demo.sh SECONDS jade). Adapted from Omarchy
-- (https://github.com/basecamp/omarchy, MIT, commit 9e0b5e2f2759):
-- default/hypr/looknfeel.lua, default/hypr/glass.lua and the Jade Horse
-- accent; foot-jade.ini is its foot theme. Changed for the iPad: scale 2,
-- the wallpaper through Hyprland's own (wall0.png; Debian's chroot has no
-- swaybg), a window opacity just below 1 (see decoration), and slower
-- window moves: Omarchy's 0.3 s ease-out jumps a thrown window 150-250 px
-- per frame, which a 60 Hz panel shows as separate copies of it
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 2 })

local active_border_color = "rgb(8bcbb1)"
local inactive_border_color = "rgba(595959aa)"

hl.config({
    general = {
        gaps_in = 5,
        gaps_out = 10,
        border_size = 2,
        col = {
            active_border = active_border_color,
            inactive_border = inactive_border_color,
        },
        layout = "dwindle",
    },
    decoration = {
        rounding = 0,
        -- below 1, so Hyprland blurs behind foot too: it treats foot's
        -- buffer as opaque although its background is see-through
        active_opacity = 0.97,
        inactive_opacity = 0.97,
        shadow = { enabled = false },
        blur = {
            enabled = true,
            size = 4,
            passes = 2,
            new_optimizations = true,
            xray = false,
            contrast = 1.0,
            brightness = 0.75,
            noise = 0.01,
            vibrancy = 0.35,
            vibrancy_darkness = 0.35,
            popups = true,
            special = true,
        },
    },
    animations = { enabled = true },
    dwindle = { preserve_split = true, force_split = 2 },
    misc = {
        disable_hyprland_logo = false, -- draws wall0.png
        disable_splash_rendering = true,
        disable_hyprland_guiutils_check = true,
        disable_watchdog_warning = true,
        disable_scale_notification = true,
        background_color = "rgb(000000)",
    },
})

hl.curve("easeOutQuint", { type = "bezier", points = { { 0.23, 1 }, { 0.32, 1 } } })
hl.curve("easeInOutCubic", { type = "bezier", points = { { 0.65, 0.05 }, { 0.36, 1 } } })
hl.curve("linear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } })
hl.curve("almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1.0 } } })
hl.curve("quick", { type = "bezier", points = { { 0.15, 0 }, { 0.1, 1 } } })

hl.animation({ leaf = "global", enabled = true, speed = 8, bezier = "default" })
hl.animation({ leaf = "border", enabled = true, speed = 4.31, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows", enabled = true, speed = 3.03, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 3.28, bezier = "easeOutQuint", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.19, bezier = "linear", style = "popin 87%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 10, bezier = "easeInOutCubic" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 1.38, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 1.17, bezier = "almostLinear" })
hl.animation({ leaf = "fade", enabled = true, speed = 2.42, bezier = "quick" })
hl.animation({ leaf = "fadeSwitch", enabled = false })
hl.animation({ leaf = "layers", enabled = true, speed = 3.05, bezier = "easeOutQuint" })
hl.animation({ leaf = "workspaces", enabled = false })

hl.on("hyprland.start", function ()
    hl.exec_cmd("foot -c /root/foot-jade.ini sh /root/demo-term.sh info")
    hl.exec_cmd("foot -c /root/foot-jade.ini sh /root/demo-term.sh palette")
    hl.exec_cmd("foot -c /root/foot-jade.ini sh /root/demo-term.sh clock")
end)

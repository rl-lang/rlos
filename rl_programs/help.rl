/*
 * help - rlOS keybindings and commands.
 *
 * WHY THIS EXISTS
 * ---------------
 * i3 ships no cheat sheet and its defaults assume you already know them. So the
 * first thing a new user needs - "what key does what?" - is the one thing the
 * desktop cannot tell them.
 *
 * It is bound to Super+Shift+? in i3.config, which runs it inside a terminal:
 *
 *   bindsym $mod+Shift+question exec $term -e /bin/rl run \
 *       /home/user/programs/rl/help.rl
 *
 * build_x11.sh checks every i3 combination printed here against the real
 * keymap in etc-rlos/i3.config, so this file cannot quietly drift away from
 * what is actually bound. That check is the reason the binding above and the
 * rows below cannot disagree. The terminal rows are mlterm's compiled-in
 * defaults, which build_x11.sh does not restate and therefore cannot check.
 *
 * rl notes, same traps as the other programs here:
 *   - a function must not end in an if/else used as its implicit return value;
 *     write explicit `return`s
 *   - concat is a free function from std::str
 *   - arr_push does not mutate; reassign it
 *   - no .err(); report failures in your own words
 */

get * from std::io
get * from std::str
get len from std

/* Defined before section(), which calls it: rl resolves names in order, so a
 * helper has to appear above its first use - there are no forward declarations.
 */
fn repeat(string s, int n)
{
    dec string out = ""
    dec int i = 0
    while i < n
    {
        out = concat(out, s)
        i = i + 1
    }
    return out
}

fn section(string title)
{
    println("")
    println(concat("  ", title))
    println(concat("  ", repeat("-", 66)))
}

fn row(string keys, string what)
{
    /* Pad by eye with a fixed field so the columns line up without needing a
     * printf-style format specifier. */
    dec string line = concat("    ", keys)
    dec int pad = 24 - len(keys)?
    dec int i = 0
    while i < pad
    {
        line = concat(line, " ")
        i = i + 1
    }
    println(concat(line, what))
}

fn main()
{
    println("")
    println("  rlOS - what to press, and what to type")
    println("  ======================================")

    section("WINDOW MANAGER (i3)   the key is Super")
    row("Super + Shift + ?", "this help")
    row("Super + Return", "new terminal")
    row("Super + f", "file manager")
    row("Super + d", "application menu")
    row("Super + 1 .. 9", "go to a workspace")
    row("Super + Shift + 1 .. 9", "move this window to a workspace")
    row("Super + Left / Right", "previous / next workspace")
    row("Super + h / j / k / l", "focus left / down / up / right")
    row("Super + Shift + h/j/k/l", "move the focused window")
    row("Super + Shift + d", "split the focused window")
    row("Super + Shift + s", "stacking layout")
    row("Super + Shift + w", "tabbed layout")
    row("Super + Shift + Space", "float / unfloat a window")
    row("Super + Shift + f", "fullscreen toggle")
    row("Super + Shift + c", "reload the config, keeping windows")
    row("Super + Shift + e", "restart i3, keeping windows")
    row("Super + Shift + q", "close the focused window")
    println("")
    println("    The session starts on workspace 1, and a new terminal opens on")
    println("    whichever workspace you are already on.")
    println("")
    section("SCRIPTS   in ~/scripts, read them, they are examples")
    row("atom-make.sh", "unpack the atom image, once")
    row("atom-shell.sh", "shell in a container")
    row("atom-ssh.sh", "a container you can ssh into")
    row("shot.sh", "screenshot")
    row("record.sh / stop", "record the screen, then stop")
    row("play.sh", "play a recording")

    section("TERMINAL (mlterm)")
    row("Shift + PageUp", "enter scrollback, half a page up")
    row("Shift + Up", "scroll back one line")
    row("wheel", "scroll; Ctrl pages, Shift one line")
    row("select, middle click", "copy, then paste the selection")
    row("Shift + Insert", "paste the selection")
    row("Ctrl + Shift + Return", "copy mode: h/j/k/l move, / searches,")
    row("", "Space selects, Return copies, q quits")
    println("")
    println("    Scrollback is built in, so no multiplexer is needed. While")
    println("    scrolled back, PageUp/PageDown, Up/Down and j/k/u/d move; any")
    println("    other key returns you to the prompt. The left button selects")
    println("    and copies to the primary selection; middle click pastes it.")

    section("COMMANDS")
    row("rl run <prog>.rl", "run an rl program from source")
    row("log", "all logs, tailed")
    row("log init", "what init did at boot")
    row("log kmsg 100", "last 100 kernel messages")
    row("log xorg", "what Xorg logged")
    row("log xorgconf 0", "the config Xorg was handed, in full")
    row("rlperf", "measure framebuffer and CPU cost")
    row("nano", "edit a file")
    row("rlfc", "compile rl programs")
    row("i3-msg restart", "restart i3 from a terminal")
    row("i3-msg reload", "reload the config from a terminal")
    row("shutdown", "sync, then power off")
    row("reboot", "sync, then restart")
    row("rescue", "busybox ash, if rl will not start")

    section("AND THE SHELL")
    println("    Your shell is busybox ash. It has the full applet set and")
    println("    does real line editing, history and Ctrl-R, so this works:")
    println("")
    println("        cd /etc")
    println("        ls -l")
    println("        nano somefile")
    println("")
    println("    rl programs are source, not compiled binaries. To run one:")
    println("")
    println("        rl run /home/user/programs/rl/log.rl")
    println("")
    println("    `help` is one of them, which is what you are reading.")
    println("")

    println("")
    println("  If mlterm will not open, there is no terminal to type in, so")
    println("  read the logs a different way:")
    println("")
    println("    Ctrl+Alt+F1  text console with a shell prompt (X is on vt7)")
    println("    log          then shows the same logs, mlterm included")
    println("")
}
/*
 * log - show the guest's logs.
 *
 * WHY THIS EXISTS
 * ---------------
 * Once the desktop is up, the console stops being somewhere you can read
 * anything. Xorg puts the physical display on its own VT, so every message
 * printed after X starts scrolls on a console hidden behind the desktop, and a
 * laptop has no serial port to read it from instead. The alternative is being
 * asked to transcribe a screen you cannot reach.
 *
 * init therefore writes three logs under /log:
 *   init.log   what init did, including the lines explaining why Xorg or udevd
 *              went wrong
 *   kmsg       the kernel stream, via klogd, uncolored
 *   Xorg.log   whatever Xorg itself wrote
 *
 * mlterm adds a fourth, but not here: it owns $HOME/.mlterm/msg.log and there
 * is no option to relocate it, so that path is read directly.
 *
 * and this prints them. The default is the *tail* of each, because the
 * interesting line is almost always the last thing that happened, rather than
 * dumping a whole boot scrollback into the terminal.
 *
 * rl-lang notes, learned the hard way and recorded here so the next edit does
 * not have to rediscover them. Bare names resolve only from what is imported,
 * and a name resolved to nothing fails at RUNTIME with a type error, not at
 * compile time - so the imports are all deliberate:
 *   is_err    from std::res, NOT std. Without it, is_err() resolves to
 *             nothing and reports as "cannot call method is_err on ok"
 *   len       from std individually; it is not part of the std::array
 *             wildcard. Returns result int, so every use needs ?
 *   arr_push  from std::array; it is a free function and does not mutate, it
 *             returns a new array, so `a = arr_push(a, x)?` is the form.
 *             There is no a.push(x) method at all.
 *   to_string from std::types
 *   concat    from std::str, as a free function: concat(a, b), not a.concat(b)
 *
 * And one that is not an import, because it cost the most time to find: a
 * function must not end in an if/else used as its implicit return value.
 * That compiled, ran, and returned NOTHING - the caller silently got an empty
 * array, with no diagnostic anywhere, which is why `load` printed its header
 * and then no lines. Write the branches as explicit `return` statements
 * instead. `return` inside a branch is fine; it is only the implicit
 * if/else-as-last-expression form that loses the value.
 */

get * from std::io
get * from std::fs
get * from std::process
get * from std::str
get * from std::array
get * from std::res
get arr_push from std::array
get len from std
get * from std::types

dec string LOG_DIR = "/log"

/* How many trailing lines to show when no count is given: enough to cover a
 * boot's worth of warnings without filling the terminal. */
dec int DEFAULT_TAIL = 40

/*
 * Read a log and return its lines, or one explanatory line in its place.
 *
 * A missing log is a normal state, not an error: the file only exists once
 * whatever writes it has started, so on a text-only boot there is no kmsg, and
 * "no such file" would read like a fault.
 */
fn load(string fname, int tail) -> arr[string]
{
    dec result[arr[string]] r = fname.read_lines()

    if r.is_err()
    {
        dec arr[string] missing = []
        missing = arr_push(missing, concat("(", fname, ": not present)")).result_unwrap()
        return missing
    }

    dec arr[string] all = r.result_unwrap()
    dec int total = len(all).result_unwrap()
    if tail <= 0 or total <= tail
    {
        return all
    }

    dec arr[string] out = []
    dec int i = total - tail
    while i < total
    {
        out = arr_push(out, all[i]).result_unwrap()
        i = i + 1
    }
    return out
}

fn show(string title, string fname, int tail)
{
    println(concat("=== ", title, "  (", fname, ") ==="))
    dec arr[string] lines = load(fname, tail)
    dec int total = len(lines)?
    dec int i = 0
    while i < total
    {
        println(lines[i])
        i = i + 1
    }
    println("")
}

/* Loose matching so `log kernel` and `log kmsg` both work. Three logs; no need
 * to be pedantic about which spelling. */
fn wants(string want, string name) -> bool
{
    want.contains(name)
}

fn main()
{
    dec arr[string] Args = args()

    dec string init_log = concat(LOG_DIR, "/init.log")
    dec string kmsg_log = concat(LOG_DIR, "/kmsg")
    dec string xorg_log = concat(LOG_DIR, "/Xorg.log")
    dec string xorg_conf = concat(LOG_DIR, "/xorg.conf")
    /* mlterm writes to its own rc directory, not /log: there is no option to
     * move it, the path is fixed by bl_set_msg_log_file_name("mlterm/msg.log")
     * under $HOME=/home/user. It is created on demand if mlterm ever logs. */
    dec string mlterm_log = "/home/user/.mlterm/msg.log"

    /* `log` on its own: every log, tail only. The form to reach for when
     * something broke and it is not yet clear which part. */
    if Args.arr_is_empty()?
    {
        show("init", init_log, DEFAULT_TAIL)
        show("kernel", kmsg_log, DEFAULT_TAIL)
        show("Xorg", xorg_log, DEFAULT_TAIL)
        show("generated xorg.conf", xorg_conf, 0)
        if mlterm_log.path_exists()
        {
            show("mlterm", mlterm_log, DEFAULT_TAIL)
        }
        return
    }

    dec string want = Args[0]

    /* `log <name> [lines]`. An explicit count shows more; 0 means all of it. */
    dec int tail = DEFAULT_TAIL
    if len(Args)? >= 2
    {
        dec result[int] n = Args[1].to_int()
        if !n.is_err()
        {
            tail = n?
        }
    }

    dec int shown = 0

    if wants(want, "init")
    {
        show("init", init_log, tail)
        shown = shown + 1
    }
    if wants(want, "kmsg") or wants(want, "kernel")
    {
        show("kernel", kmsg_log, tail)
        shown = shown + 1
    }
    if wants(want, "xorgconf")
    {
        /* The config Xorg was actually handed, not a log about it. When the
         * session will not start this is the file that decides it. */
        show("generated xorg.conf", xorg_conf, 0)
        shown = shown + 1
    }
    else if wants(want, "xorg")
    {
        show("Xorg", xorg_log, tail)
        shown = shown + 1
    }
    /* The terminal is the one client whose stderr nobody can see, so if it
     * fails at startup this file is the only evidence that anything went
     * wrong. Shown on request as `log mlterm`, and also whenever it exists,
     * because the failure you did not know to ask about is the one that
     * matters. */
    if wants(want, "mlterm") or mlterm_log.path_exists()
    {
        show("mlterm", mlterm_log, tail)
        shown = shown + 1
    }

    if shown == 0
    {
        println(concat("no log matches \"", want,
                       "\". try: log init | log kmsg | log xorg | log xorgconf | log mlterm"))
        println("    (mlterm is also shown whenever it has written one)")
    }
}
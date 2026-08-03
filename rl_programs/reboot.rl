/*
 * reboot - restart the machine.
 *
 * Same mechanism as shutdown, one key different. See the long comment in
 * shutdown.rl for why this goes through /proc/sysrq-trigger rather than a raw
 * reboot(2) syscall - briefly: rl exposes __syscall6(), but getting the x86-64
 * syscall number or its argument struct wrong restarts the machine in an
 * uncontrolled way, whereas a mistyped sysrq key does nothing at all.
 *
 * The two keys used here:
 *   s  sync  - flush the filesystem cache
 *   b  reboot
 *
 * 'b' is sysrq_reboot_op in drivers/tty/sysrq.c, which calls
 * emergency_restart(). Note that it does NOT sync first, so the 's' here is
 * doing real work: without it, anything still in the page cache is lost.
 *
 * Both keys go through /proc/sysrq-trigger, whose write path calls
 * __handle_sysrq(c, false) and so ignores the sysrq enable mask. That is what
 * makes them work despite CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x1 not covering
 * SYSRQ_ENABLE_BOOT.
 *
 * Two separate writes, not one "sb". write_sysrq_trigger() stops after the
 * first character unless it sees '_' - which selects bulk mode - so a single
 * write of "sb" would run only the sync and silently skip the reboot.
 */

get * from std::fs
get * from std::io
get is_err from std::res

/* Fire one sysrq key. False means /proc/sysrq-trigger could not be written. */
fn trigger(string key) -> bool
{
    dec string path = "/proc/sysrq-trigger"
    dec r = path.write_file(key)
    if r.is_err()
    {
        return false
    }
    return true
}

fn main()
{
    println("reboot: syncing, then rebooting")

    if !trigger("s")
    {
        println("reboot: could not sync, rebooting anyway")
    }

    if trigger("b")
    {
        println("reboot: the reboot handler returned without rebooting")
        return
    }

    println("reboot: could not trigger reboot - not root, or no MAGIC_SYSRQ in")
    println("reboot: the kernel. Hard reset is the only option left.")
}
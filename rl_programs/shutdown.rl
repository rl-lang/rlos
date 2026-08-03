/*
 * shutdown - power the machine off.
 *
 * WHY sysrq INSTEAD OF A REBOOT(2) SYSCALL
 * -----------------------------------------
 * There is no poweroff() binding in rl's stdlib, and the obvious thing to
 * reach for - a raw syscall - is a trap here. rl does expose __syscall6(), but
 * the numbers it wants are the x86-64 ones, and a wrong guess reboots the
 * machine instead of powering it off, with no chance to report what went wrong.
 * sysrq needs no syscall number to get right: the key is a single character,
 * and if it is wrong the machine simply does not change state.
 *
 * HOW IT WORKS
 * ------------
 * Writing to /proc/sysrq-trigger runs a kernel emergency handler. The keys we
 * care about are:
 *   s  sync - flush the filesystem cache
 *   o  power off
 *   b  reboot
 *
 * Two details make this safe to rely on, and both were checked in the source
 * rather than assumed:
 *
 *  1. The handler is NOT gated by the kernel's sysrq enable mask. In
 *     drivers/tty/sysrq.c, write_sysrq_trigger() calls __handle_sysrq(c, false)
 *     - check_mask false - while the keyboard path passes true and consults
 *     sysrq_enable_mask. That matters because our kernel sets
 *     CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x1, which covers only the console
 *     loglevel: it does NOT include SYSRQ_ENABLE_BOOT (0x80) or
 *     SYSRQ_ENABLE_SYNC (0x10). If the proc path were masked, 'o' and 'b'
 *     would print "This sysrq operation is disabled." and quietly do nothing.
 *
 *  2. The kernel builds poweroff in. kernel/power/poweroff.c registers 'o' from
 *     pm_sysrq_init() via a subsys_initcall, and poweroff.o is in the image.
 *     This is worth checking, because the 'o' entry in the tty table in sysrq.c
 *     is NULL - poweroff is wired up from outside that table, so reading
 *     sysrq.c alone would suggest the key does not exist.
 *
 * /proc/sysrq-trigger is S_IWUSR, so this only works as root, which rlsh runs
 * as.
 *
 * The sync is not cosmetic. 'o' does not sync first on its own; it just stops
 * the CPUs and cuts power, so anything still in the page cache is lost.
 *
 * rl notes, both found the hard way:
 *   write_file is called as a method on a *variable*, never on a string
 *     literal - `"/proc/sysrq-trigger".write_file("s")` is a parse error
 *     ("expected `=` after name"). nano.rl does it the same way.
 *   is_err must be imported from std::res. Without the import it resolves to
 *     nothing and fails at runtime with "cannot call method is_err on ok".
 *   there is no .err(), so the failure path reports in its own words instead
 *     of printing a value it cannot get at.
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
    println("shutdown: syncing, then powering off")

    /*
     * Carry on and power off even if the sync fails. A failed sync is bad, but
     * leaving the machine running is worse - the user asked for it to go away,
     * and this is a live ISO with nothing on it to lose.
     */
    if !trigger("s")
    {
        println("shutdown: could not sync, powering off anyway")
    }

    if trigger("o")
    {
        /*
         * Reached only if the poweroff handler returned, which should not
         * happen: 'o' schedules work that stops the CPUs and powers down. If it
         * does return, say so rather than exiting silently, because init will
         * restart this program and the user would otherwise see nothing at all.
         */
        println("shutdown: the poweroff handler returned without powering off")
        return
    }

    /*
     * Reached only when /proc/sysrq-trigger could not be written: we are not
     * root, or CONFIG_MAGIC_SYSRQ is off. Nothing further is possible from
     * userspace.
     */
    println("shutdown: could not trigger poweroff - not root, or no MAGIC_SYSRQ")
    println("shutdown: in the kernel. Hard power off is the only option left.")
}
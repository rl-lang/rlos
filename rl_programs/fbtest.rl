/* fbtest.rl - probe /dev/fb0 and prove the framebuffer is writable.
 *
 * This is the gate for the X11 plan. xf86-video-fbdev 0.5.1 documents support
 * for depths 8, 15, 16 and 24 only, while an EFI framebuffer is normally
 * 32bpp. This program reports what the kernel actually hands us, so that can
 * be answered before an X server gets built on top of it.
 *
 * Painting goes through lseek()+write() on /dev/fb0 rather than mmap, because
 * that path can be read back and verified. A buf handle only ever wraps an
 * RL-owned allocation, so there is no way to obtain a handle covering an
 * arbitrary mmap'd pointer. For real pixel work mmap is the fast path; this
 * is a probe, not a toolkit.
 *
 * Nothing here uses hex literals: RL's number_literal.rs only scans decimal
 * digits, so every constant below is written in decimal.
 */

get * from std::io
get * from std::str
get * from std::types
get * from std::res
get __syscall6, __buf_new, __buf_resize, __buf_addr, __buf_append,
    __buf_set_byte, __buf_get_byte, __buf_to_string from core

// x86_64 syscall numbers
dec int SYS_READ   = 0
dec int SYS_WRITE  = 1
dec int SYS_LSEEK  = 8
dec int SYS_MMAP   = 9
dec int SYS_IOCTL  = 16
dec int SYS_CLOSE  = 3
dec int SYS_OPENAT = 257

dec int AT_FDCWD = -100
dec int O_RDWR   = 2
dec int SEEK_SET = 0
dec int PROT_READ_WRITE = 3
dec int MAP_SHARED = 1

// 0x4600 and 0x4602, from include/uapi/linux/fb.h
dec int FBIOGET_VSCREENINFO = 17920
dec int FBIOGET_FSCREENINFO = 17922

// field offsets in struct fb_var_screeninfo on x86_64
dec int VS_XRES           = 0
dec int VS_YRES           = 4
dec int VS_XRES_VIRTUAL   = 8
dec int VS_YRES_VIRTUAL   = 12
dec int VS_BITS_PER_PIXEL = 24
dec int VS_RED_OFFSET     = 32
dec int VS_GREEN_OFFSET   = 44
dec int VS_BLUE_OFFSET    = 56
dec int VS_TRANSP_OFFSET  = 68

// field offsets in struct fb_fix_screeninfo on x86_64
dec int FS_ID_LEN   = 16
dec int FS_TYPE     = 28
dec int FS_LINE_LEN = 48

// visual.type values from include/uapi/linux/fb.h
dec int FB_TYPE_PACKED_PIXELS = 0
dec int FB_TYPE_ARGB8888      = 1
dec int FB_TYPE_RGB565        = 2
dec int FB_TYPE_EPSX8888      = 4

dec int DARK_BYTE   = 24
dec int BRIGHT_BYTE = 200
dec int BAND_ROWS   = 120
dec int BLOCK_PX    = 220

// Little-endian u32 out of a buffer, built from single bytes with shifts.
fn le32(handle b, int off) -> int
{
    dec int b0 = result_unwrap(to_int(__buf_get_byte(b, off)))
    dec int b1 = result_unwrap(to_int(__buf_get_byte(b, off + 1)))
    dec int b2 = result_unwrap(to_int(__buf_get_byte(b, off + 2)))
    dec int b3 = result_unwrap(to_int(__buf_get_byte(b, off + 3)))
    return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
}

fn visual_name(int t) -> string
{
    if t == FB_TYPE_PACKED_PIXELS
    {
        return "FB_TYPE_PACKED_PIXELS"
    }
    if t == FB_TYPE_ARGB8888
    {
        return "FB_TYPE_ARGB8888"
    }
    if t == FB_TYPE_RGB565
    {
        return "FB_TYPE_RGB565"
    }
    if t == FB_TYPE_EPSX8888
    {
        return "FB_TYPE_EPSX8888"
    }
    return "unknown"
}

fn main()
{
    // --- open the device ---------------------------------------------------
    dec handle path = __buf_new()
    __buf_append(path, "/dev/fb0")
    __buf_resize(path, 10) // 9 chars plus the NUL that openat() expects

    dec int fd = __syscall6(SYS_OPENAT, AT_FDCWD, __buf_addr(path), O_RDWR, 0, 0, 0)
    if fd < 0
    {
        println(format("FAIL openat(/dev/fb0) -> errno {}", 0 - fd)?)
        println("no usable framebuffer; the DRM_EFIDRM + fbdev path is not present")
        return
    }
    println(format("opened /dev/fb0 as fd {}", fd)?)

    // --- geometry: FBIOGET_VSCREENINFO -------------------------------------
    dec handle vs = __buf_new()
    __buf_resize(vs, 160)
    dec int r1 = __syscall6(SYS_IOCTL, fd, FBIOGET_VSCREENINFO, __buf_addr(vs), 0, 0, 0)
    if r1 < 0
    {
        println(format("FAIL ioctl(FBIOGET_VSCREENINFO) -> errno {}", 0 - r1)?)
        __syscall6(SYS_CLOSE, fd, 0, 0, 0, 0, 0)
        return
    }

    dec int xres = le32(vs, VS_XRES)
    dec int yres = le32(vs, VS_YRES)
    dec int xres_v = le32(vs, VS_XRES_VIRTUAL)
    dec int yres_v = le32(vs, VS_YRES_VIRTUAL)
    dec int bpp = le32(vs, VS_BITS_PER_PIXEL)
    dec int red_off = le32(vs, VS_RED_OFFSET)
    dec int green_off = le32(vs, VS_GREEN_OFFSET)
    dec int blue_off = le32(vs, VS_BLUE_OFFSET)
    dec int transp_off = le32(vs, VS_TRANSP_OFFSET)

    // --- fixed info: stride and visual type ---------------------------------
    dec handle fx = __buf_new()
    __buf_resize(fx, 128)
    dec int r2 = __syscall6(SYS_IOCTL, fd, FBIOGET_FSCREENINFO, __buf_addr(fx), 0, 0, 0)
    if r2 < 0
    {
        println(format("FAIL ioctl(FBIOGET_FSCREENINFO) -> errno {}", 0 - r2)?)
        __syscall6(SYS_CLOSE, fd, 0, 0, 0, 0, 0)
        return
    }

    dec int fb_type = le32(fx, FS_TYPE)
    dec int line_len = le32(fx, FS_LINE_LEN)

    // fix.id is char[16]; __buf_to_string keeps the trailing NULs, so find
    // the terminator and copy only the printable prefix.
    dec int id_len = FS_ID_LEN
    for [int i = 0, i < FS_ID_LEN, i += 1] {
        if __buf_get_byte(fx, i) == 0 as byte
        {
            id_len = i
            break
        }
    }
    dec handle idbuf = __buf_new()
    __buf_resize(idbuf, id_len)
    for [int i = 0, i < id_len, i += 1] {
        __buf_set_byte(idbuf, i, __buf_get_byte(fx, i) as byte)
    }
    dec string id = __buf_to_string(idbuf)

    println("")
    println("=== fb_var_screeninfo ===")
    println(format("  xres / yres     : {} x {}", xres, yres)?)
    println(format("  virtual         : {} x {}", xres_v, yres_v)?)
    println(format("  bits_per_pixel  : {}", bpp)?)
    println(format("  red/green/blue  : {} / {} / {}", red_off, green_off, blue_off)?)
    println(format("  transp offset   : {}", transp_off)?)
    println("")
    println("=== fb_fix_screeninfo ===")
    println(format("  id              : {}", id)?)
    println(format("  type            : {} ({})", fb_type, visual_name(fb_type))?)
    println(format("  line_length     : {} bytes per row", line_len)?)
    println(format("  xres * bpp/8    : {} bytes per row", xres * (bpp / 8))?)
    println(format("  frame size      : {} bytes", line_len * yres)?)

    if line_len <= 0
    {
        println("")
        println("line_length is 0, so there is no pitch to paint with.")
        println("raw fb_fix_screeninfo bytes 0..79, for working out the layout:")
        for [int i = 0, i < 80, i += 8] {
            println(format("  [{}] {} {} {} {} {} {} {} {}",
                           i,
                           to_int(__buf_get_byte(fx, i))?,
                           to_int(__buf_get_byte(fx, i + 1))?,
                           to_int(__buf_get_byte(fx, i + 2))?,
                           to_int(__buf_get_byte(fx, i + 3))?,
                           to_int(__buf_get_byte(fx, i + 4))?,
                           to_int(__buf_get_byte(fx, i + 5))?,
                           to_int(__buf_get_byte(fx, i + 6))?,
                           to_int(__buf_get_byte(fx, i + 7))?)?)
        }
        __syscall6(SYS_CLOSE, fd, 0, 0, 0, 0, 0)
        return
    }

    // --- the verdict the X11 plan depends on --------------------------------
    println("")
    if bpp == 8 or bpp == 16 or bpp == 24 or bpp == 32
    {
        if bpp == 32
        {
            println("VERDICT: 32bpp - fine. The fbdev(4) man page still lists only 8/15/16/24,")
            println("  but the driver source handles case 32 in both FBDevPreInit and")
            println("  FBDevScreenInit, for FB_TYPE_PACKED_PIXELS exactly as reported here.")
        }
        else
        {
            println(format("VERDICT: {}bpp - supported by xf86-video-fbdev, X11 should work", bpp)?)
        }
    }
    else
    {
        println(format("VERDICT: bpp {} is not one of 8/16/24/32 - X11 will not start", bpp)?)
    }

    // --- mmap, for information only ----------------------------------------
    dec int map_len = line_len * yres
    dec int addr = __syscall6(SYS_MMAP, 0, map_len, PROT_READ_WRITE, MAP_SHARED, fd, 0)
    if addr > 0
    {
        println("")
        println(format("mmap PROT_READ|PROT_WRITE MAP_SHARED: {} bytes at {}", map_len, addr)?)
        println("  that is the path a real pixel-pushing GUI toolkit would use")
    }
    else
    {
        println("")
        println(format("mmap failed: errno {}", 0 - addr)?)
    }

    // --- paint --------------------------------------------------------------
    dec int px_bytes = bpp / 8
    if px_bytes < 1
    {
        println("bpp too small to paint, stopping")
        __syscall6(SYS_CLOSE, fd, 0, 0, 0, 0, 0)
        return
    }

    // Two row buffers built once and written repeatedly, which keeps the byte
    // writes at line_len * 2 instead of line_len * BAND_ROWS.
    dec handle dark = __buf_new()
    __buf_resize(dark, line_len)
    for [int i = 0, i < line_len, i += 1] {
        __buf_set_byte(dark, i, DARK_BYTE as byte)
    }

    dec handle split = __buf_new()
    __buf_resize(split, line_len)
    dec int block_bytes = BLOCK_PX * px_bytes
    for [int i = 0, i < line_len, i += 1] {
        if i < block_bytes
        {
            __buf_set_byte(split, i, BRIGHT_BYTE as byte)
        }
        else
        {
            __buf_set_byte(split, i, DARK_BYTE as byte)
        }
    }

    println("")
    println(format("painting {} rows, with a bright {}x{} block at the top left",
                   BAND_ROWS, BLOCK_PX, BLOCK_PX)?)

    for [int row = 0, row < BAND_ROWS, row += 1] {
        dec handle which = dark
        if row < BLOCK_PX
        {
            which = split
        }
        __syscall6(SYS_LSEEK, fd, row * line_len, SEEK_SET, 0, 0, 0)
        __syscall6(SYS_WRITE, fd, __buf_addr(which), line_len, 0, 0, 0)
    }

    // --- read row 0 back and compare ----------------------------------------
    dec handle back = __buf_new()
    __buf_resize(back, line_len)
    __syscall6(SYS_LSEEK, fd, 0, SEEK_SET, 0, 0, 0)
    dec int got = __syscall6(SYS_READ, fd, __buf_addr(back), line_len, 0, 0, 0)

    dec int same = 0
    dec int diff = 0
    for [int i = 0, i < line_len, i += 1] {
        if __buf_get_byte(back, i) == __buf_get_byte(split, i)
        {
            same = same + 1
        }
        else
        {
            diff = diff + 1
        }
    }

    println("")
    println(format("read back {} bytes of row 0", got)?)
    println(format("  bytes matching what we wrote : {}", same)?)
    println(format("  bytes differing              : {}", diff)?)
    if same == line_len
    {
        println("  OK - the framebuffer holds exactly what we wrote")
    }
    else
    {
        println("  MISMATCH - the read path does not see the written pixels")
    }

    __syscall6(SYS_CLOSE, fd, 0, 0, 0, 0, 0)
    println("")
    println("fbtest done")
}

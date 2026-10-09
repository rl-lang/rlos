// imports
get * from std::res;
get * from std::term; get * from std::io; get * from std::path; get * from std::str;
get * from std::array; get * from std::process; get std::res::result_unwrap; get len from std;
get * from std::fs; get * from std::math; get * from std::types;

record Editor
{
    arr[string] lines,
    arr[string] log,
    string filename,
    string message,
    int cursor_row,
    int cursor_col,
    int scroll_left,
    int scroll_top,
    // Set while the horizontal viewport has been deliberately panned with
    // Ctrl+Left / Ctrl+Right. ensure_cursor_visible runs after EVERY keypress
    // and would otherwise snap the view straight back to the cursor on the very
    // next frame, making the pan keys do nothing at all. `pan_col` records the
    // cursor column the pan was made from, so the pan survives until the cursor
    // actually moves - which is what nano does - rather than lasting one frame.
    bool pan_held,
    int pan_col,
    // One line, held as a plain string. A fresh cut REPLACES it rather than
    // adding to it, so the buffer never grows to hold a run of lines, and
    // pasting does not clear it, so the same line can be pasted again and
    // again - which is the point of a cut/paste pair with no separate copy.
    string clipboard,
    bool running,
    bool dirty,
    bool confirm_quit,
    int status_timer,
}

// ---- viewport helpers ------------------------------------------------------
// 
// These live ABOVE `impl Editor` on purpose, not for readability but because
// rlt emits functions into the C file in source order. The Editor methods call
// view_cols(), so declared below them the generated C reads
// 
// nano.c:175: implicit declaration of function 'view_cols'
// nano.c:406: conflicting types for 'view_cols'
// 
// and an implicit declaration is an error under -std=c11, the dialect rlt pins.
// They depend only on stdlib, never on the Editor record, so they can sit here.
// The text area is everything to the right of the line-number gutter.
// `draw` computes this as `gutter_width = 7` (a 6-wide number plus one space),
// but the cursor-follow logic needs the same number, so it lives here instead
// of being a local in draw and being recomputed - and drifted - elsewhere.
fn view_cols() -> int
{
    dec arr[int] sz = term_get_size().result_unwrap_or([80, 24])
    dec int w = sz[0] - 7
    if (w < 1)
    {
        w = 1
    }
    return w
}

// Print only the part of the token spanning [a, b) that falls inside the
// viewport [from, to).
// 
// The highlighter must keep scanning the WHOLE line and clip only at print
// time. Slicing the line first and highlighting the slice breaks tokenization:
// a string that opens at column 50 and is clipped to 60 arrives as `"llo
// world"`, and the scanner then runs off the end of the fragment looking for a
// closing quote it can never find. Clipping here instead means a token that
// straddles the left edge prints only its tail - in the correct colour,
// because the colour was chosen from the whole token.
// 
// `slice` clamps out-of-range bounds, so indices past the end of the line are
// safe rather than an error.
fn print_span(
    string line, int a, int b, int _from, int to
    )
{
    dec int s = a
    dec int e = b
    if (s < _from)
    {
        s = _from
    }
    if (e > to)
    {
        e = to
    }
    if (e > s)
    {
        term_print(slice(line, s, e).result_unwrap_or(""))
    }
}

// The same window for a line printed verbatim, i.e. one `draw` is not
// highlighting it (any filename that does not end in `.rl`).
fn print_window(string line, int _from, int to)
{
    dec int n = len(line).result_unwrap_or(0)
    dec int e = n
    if (e > to)
    {
        e = to
    }
    if (e > _from)
    {
        term_print(slice(line, _from, e).result_unwrap_or(""))
    }
}
impl Editor
{

    fn stop(self)
    {
        if self.dirty
        {
            self.confirm_quit = true
        }
        else
        {
            self.running = false
        }
    }

    fn save_buffer(self)
    {
        self.filename.write_file(self.lines.join("\n").result_unwrap())
        self.dirty = false
        self.message = "Saved: {}".format(self.filename)
        self.status_timer = 20
    }

    fn move_cursor_up(self)
    {
        if (self.cursor_row > 0)
        {
            self.cursor_row = self.cursor_row - 1
            dec l = self.lines
            dec int ll = len(l[self.cursor_row]).result_unwrap()
            if (self.cursor_col > ll)
            {
                self.cursor_col = ll
            }
        }
        self.status_timer = clamp(self.status_timer - 1, 0, 20).result_unwrap_or(self.status_timer)
    }

    fn move_cursor_down(self)
    {
        if (self.cursor_row < len(self.lines).result_unwrap() - 1)
        {
            self.cursor_row = self.cursor_row + 1
            dec l = self.lines
            dec int ll = len(l[self.cursor_row]).result_unwrap()
            if (self.cursor_col > ll)
            {
                self.cursor_col = ll
            }
        }
        self.status_timer = clamp(self.status_timer - 1, 0, 20).result_unwrap_or(self.status_timer)
    }

    fn move_page_up(self)
    {
        dec arr[int] size = term_get_size().result_unwrap_or([0, 0])
        dec int page = size[1] - 3
        if (page < 1)
        {
            page = 1
        }
        self.cursor_row = self.cursor_row - page
        if (self.cursor_row < 0)
        {
            self.cursor_row = 0
        }
        dec l = self.lines
        dec int ll = len(l[self.cursor_row]).result_unwrap()
        if (self.cursor_col > ll)
        {
            self.cursor_col = ll
        }
        self.status_timer = clamp(self.status_timer - 1, 0, 20).result_unwrap_or(self.status_timer)
    }

    fn move_page_down(self)
    {
        dec arr[int] size = term_get_size().result_unwrap_or([0, 0])
        dec int page = size[1] - 3
        if (page < 1)
        {
            page = 1
        }
        self.cursor_row = self.cursor_row + page
        dec int last_row = len(self.lines).result_unwrap() - 1
        if (self.cursor_row > last_row)
        {
            self.cursor_row = last_row
        }
        dec l = self.lines
        dec int ll = len(l[self.cursor_row]).result_unwrap()
        if (self.cursor_col > ll)
        {
            self.cursor_col = ll
        }
        self.status_timer = clamp(self.status_timer - 1, 0, 20).result_unwrap_or(self.status_timer)
    }

    fn move_cursor_to_left(self)
    {
        if (self.cursor_col > 0)
        {
            self.cursor_col = self.cursor_col - 1
        }
        else if (self.cursor_row > 0)
        {
            self.cursor_row = self.cursor_row - 1
            dec l = self.lines
            self.cursor_col = len(l[self.cursor_row]).result_unwrap()
        }
        self.status_timer = clamp(self.status_timer - 1, 0, 20).result_unwrap_or(self.status_timer)
    }

    fn move_cursor_to_right(self)
    {
        dec l = self.lines
        dec int ll = len(l[self.cursor_row]).result_unwrap()
        if (self.cursor_col < ll)
        {
            self.cursor_col = self.cursor_col + 1
        }
        else if (self.cursor_row < len(self.lines).result_unwrap() - 1)
        {
            self.cursor_row = self.cursor_row + 1
            self.cursor_col = 0
        }
        self.status_timer = clamp(self.status_timer - 1, 0, 20).result_unwrap_or(self.status_timer)
    }

    fn go_to_start_of_line(self)
    {
        self.cursor_col = 0
    }

    fn go_to_end_of_line(self)
    {
        dec l = self.lines
        self.cursor_col = len(l[self.cursor_row]).result_unwrap_or(0)
        self.status_timer = clamp(self.status_timer - 1, 0, 20).result_unwrap_or(self.status_timer)
    }

    // Bring the cursor back inside the viewport on BOTH axes, and slide the
    // horizontal viewport to match.
    // 
    // The vertical half used to live inline in main's key loop; it is here now
    // so the two axes sit together, because they have to agree: draw computes
    // the same editor_rows and the same view_cols, and if either drifts the
    // cursor ends up just off-screen and looks like a one-column bug.
    fn ensure_cursor_visible(self)
    {
        dec arr[int] sz = term_get_size().result_unwrap_or([80, 24])
        dec int editor_rows = sz[1] - 3
        if (editor_rows < 1)
        {
            editor_rows = 1
        }
        if (self.cursor_row < self.scroll_top)
        {
            self.scroll_top = self.cursor_row
        }
        if (self.cursor_row >= self.scroll_top + editor_rows)
        {
            self.scroll_top = self.cursor_row - editor_rows + 1
        }

        // A deliberate pan owns the viewport until the cursor moves. Returning
        // early here is what makes Ctrl+Left / Ctrl+Right mean anything: without
        // it the next ensure_cursor_visible (which runs after every keypress)
        // would pull scroll_left straight back under the cursor.
        if (self.pan_held and self.cursor_col == self.pan_col)
        {
            return
        }
        self.pan_held = false

        dec int vc = view_cols()
        if (self.cursor_col < self.scroll_left)
        {
            self.scroll_left = self.cursor_col
        }
        if (self.cursor_col >= self.scroll_left + vc)
        {
            self.scroll_left = self.cursor_col - vc + 1
        }

        // Scroll back, the way nano does: on a line shorter than the viewport,
        // slide left so the END of the line is visible rather than leaving it
        // stranded mid-screen with blank space to its right. This is the third
        // rule and it has to come last - without it, moving right onto a short
        // line leaves the viewport parked past its end.
        dec l = self.lines
        dec int ll = len(l[self.cursor_row]).result_unwrap_or(0)
        dec int max_left = ll - vc
        if (max_left < 0)
        {
            max_left = 0
        }
        if (self.scroll_left > max_left)
        {
            self.scroll_left = max_left
        }
    }

    // How far right the viewport may pan: the longest line currently on screen,
    // not the cursor's own line.
    // 
    // Bounding it by the cursor's line alone makes Ctrl+Right a silent no-op
    // whenever you are standing on a short line - `len(line) - view_cols()`
    // goes negative, clamps to 0, and the view cannot move - so there is no way
    // to pan across to a long line further down without first putting the
    // cursor on it. Measured: on a file whose first line is 2 bytes and second
    // is 300, two Ctrl+Right presses from the short line moved the view 0
    // columns; from the long line, 72.
    fn max_view_left(self) -> int
    {
        dec arr[int] sz = term_get_size().result_unwrap_or([80, 24])
        dec int rows = sz[1] - 3
        if (rows < 1)
        {
            rows = 1
        }
        dec int vc = view_cols()
        dec l = self.lines
        dec int n = len(l).result_unwrap_or(0)
        if (n < 1)
        {
            return 0
        }
        dec int start = self.scroll_top
        if (start > n - 1)
        {
            start = n - 1
        }
        if (start < 0)
        {
            start = 0
        }
        dec int longest = 0
        dec int i = 0
        while (i < rows)
        {
            dec int r = start + i
            if (r < n)
            {
                dec int ll = len(l[r]).result_unwrap_or(0)
                if (ll > longest)
                {
                    longest = ll
                }
            }
            i = i + 1
        }
        dec int m = longest - vc
        if (m < 0)
        {
            m = 0
        }
        return m
    }

    // Explicit horizontal panning, for looking at a long line without moving
    // the cursor.
    fn scroll_view_left(self)
    {
        self.pan_held = true
        self.pan_col = self.cursor_col
        dec int step = view_cols() / 2
        if (step < 1)
        {
            step = 1
        }
        self.scroll_left = self.scroll_left - step
        if (self.scroll_left < 0)
        {
            self.scroll_left = 0
        }
    }

    fn scroll_view_right(self)
    {
        self.pan_held = true
        self.pan_col = self.cursor_col
        dec int step = view_cols() / 2
        if (step < 1)
        {
            step = 1
        }
        dec int max_left = self.max_view_left()
        self.scroll_left = self.scroll_left + step
        if (self.scroll_left > max_left)
        {
            self.scroll_left = max_left
        }
    }

    fn scroll_view_to_left_edge(self)
    {
        self.pan_held = true
        self.pan_col = self.cursor_col
        self.scroll_left = 0
    }

    fn scroll_view_to_right_edge(self)
    {
        self.pan_held = true
        self.pan_col = self.cursor_col
        self.scroll_left = self.max_view_left()
    }

    fn insert_newline(self)
    {
        dec l = self.lines
        dec string current = l[self.cursor_row]
        dec string before = ""
        if (self.cursor_col > 0)
        {
            before = slice(current, 0, self.cursor_col).result_unwrap()
        }
        dec string after = ""
        if (self.cursor_col < len(current).result_unwrap())
        {
            after = slice(
                current,
                self.cursor_col,
                len(current).result_unwrap()
            ).result_unwrap()
        }
        l[self.cursor_row] = before
        self.lines = l
        if (self.cursor_row + 1 < len(l).result_unwrap())
        {
            self.lines = arr_insert(
                self.lines,
                after,
                self.cursor_row + 1
            ).result_unwrap()
        }
        else
        {
            self.lines = arr_push(self.lines, after).result_unwrap()
        }
        self.cursor_row = self.cursor_row + 1
        self.cursor_col = 0
        self.message = ""
        self.dirty = true
        self.status_timer = clamp(self.status_timer - 1, 0, 20).result_unwrap_or(self.status_timer)
    }

    fn delete_char_behind(self)
    {
        if (self.cursor_col > 0)
        {
            dec l = self.lines
            dec string current = l[self.cursor_row]
            dec string before = ""
            if (self.cursor_col > 1)
            {
                before = slice(current, 0, self.cursor_col - 1).result_unwrap()
            }
            dec string after = ""
            if (self.cursor_col < len(current).result_unwrap())
            {
                after = slice(
                    current,
                    self.cursor_col,
                    len(current).result_unwrap()
                ).result_unwrap()
            }
            l[self.cursor_row] = concat(before, after)
            self.lines = l
            self.cursor_col = self.cursor_col - 1
            self.message = ""
        }
        else if (self.cursor_row > 0)
        {
            dec l = self.lines
            dec int prev_len = len(l[self.cursor_row - 1]).result_unwrap()
            dec string merged = concat(
                l[self.cursor_row - 1],
                l[self.cursor_row]
            )
            l[self.cursor_row - 1] = merged
            self.lines = l
            self.lines = arr_remove(self.lines, self.cursor_row).result_unwrap()
            self.cursor_row = self.cursor_row - 1
            self.cursor_col = prev_len
            self.message = ""
        }
        self.dirty = true
        self.status_timer = clamp(self.status_timer - 1, 0, 20).result_unwrap_or(self.status_timer)
    }

    fn delete_char_forward(self)
    {
        dec l = self.lines
        dec string current = l[self.cursor_row]
        dec int ll = len(current).result_unwrap()
        if (self.cursor_col < ll)
        {
            dec string before = ""
            if (self.cursor_col > 0)
            {
                before = slice(current, 0, self.cursor_col).result_unwrap()
            }
            dec string after = ""
            if (self.cursor_col + 1 < ll)
            {
                after = slice(current, self.cursor_col + 1, ll).result_unwrap()
            }
            l[self.cursor_row] = concat(before, after)
            self.lines = l
            self.message = ""
        }
        else if (self.cursor_row < len(self.lines).result_unwrap() - 1)
        {
            dec string merged = concat(
                l[self.cursor_row],
                l[self.cursor_row + 1]
            )
            l[self.cursor_row] = merged
            self.lines = l
            self.lines = arr_remove(self.lines, self.cursor_row + 1).result_unwrap()
            self.message = ""
        }
        self.dirty = true
        self.status_timer = clamp(self.status_timer - 1, 0, 20).result_unwrap_or(self.status_timer)
    }

    fn insert_tab(self)
    {
        dec l = self.lines
        dec string current = l[self.cursor_row]
        dec string before = ""
        if (self.cursor_col > 0)
        {
            before = slice(current, 0, self.cursor_col).result_unwrap()
        }
        dec string after = ""
        if (self.cursor_col < len(current).result_unwrap())
        {
            after = slice(
                current,
                self.cursor_col,
                len(current).result_unwrap()
            ).result_unwrap()
        }
        l[self.cursor_row] = concat(before, concat("   ", after))
        self.lines = l
        self.cursor_col = self.cursor_col + 3
        self.message = ""
        self.dirty = true
        self.status_timer = clamp(self.status_timer - 1, 0, 20).result_unwrap_or(self.status_timer)
    }

    // Ctrl+K - cut the current line into the clipboard and delete it.
    // 
    // Matches nano: this cuts the WHOLE line, not the text from the cursor to
    // the end. Two edge cases nano also handles:
    // 
    // * nothing at all when the buffer has a single empty line, since
    // deleting it would leave no line for the cursor to sit on
    // * on the last remaining line, clear it rather than remove it, for the
    // same reason
    // 
    // The cut text still goes on the clipboard in both cases, so Ctrl+U brings
    // it back.
    fn cut_line(self)
    {

        // Bind a local and index that, rather than indexing `self.lines`
        // inline: the parser rejects an indexed expression as an argument to a
        // stdlib call (`len(self.lines[i])` is "expected `)` after
        // arguments"), and every other edit method here works this way.
        dec l = self.lines
        dec int n = len(l).result_unwrap_or(0)

        // No `.result_unwrap_or("")` here: the checker types a bare `l[i]` as
        // the ARRAY, not the element, so the method resolves to (String, String)
        // and fails to match an overload. The `dec string` annotation is what
        // makes it an element - which is why every other method in this impl
        // reads lines out as `dec string current = l[self.cursor_row]`.
        dec string cur = l[self.cursor_row]
        if (n <= 1 and len(cur).result_unwrap_or(0) == 0)
        {
            return
        }

        // One line only: a fresh cut REPLACES the buffer instead of adding to
        // it, so it never accumulates. The buffer survives the paste, so the
        // same line can be pasted repeatedly.
        self.clipboard = cur
        self.message = "Cut line {}".format(self.cursor_row + 1)
        self.dirty = true
        self.status_timer = 20

        if (n <= 1)
        {
            l[self.cursor_row] = ""
            self.lines = l
            self.cursor_col = 0
            return
        }

        l = arr_remove(l, self.cursor_row).result_unwrap_or(l)
        self.lines = l

        // Removing the last line leaves the cursor one past the end.
        dec int left = len(l).result_unwrap_or(0)
        if (self.cursor_row >= left)
        {
            self.cursor_row = left - 1
        }
        dec int ll = len(l[self.cursor_row]).result_unwrap_or(0)
        if (self.cursor_col > ll)
        {
            self.cursor_col = ll
        }
    }

    // Ctrl+U - paste the held line ABOVE the current line.
    // 
    // Above, not below, and the cursor stays on its own line: that lets you cut
    // a line, move somewhere else, and drop it back where you are. The buffer
    // is deliberately NOT cleared, so Ctrl+U can be pressed repeatedly to
    // duplicate the same line.
    fn paste_line(self)
    {
        dec string cb = self.clipboard
        if (len(cb).result_unwrap_or(0) == 0)
        {
            self.message = "Nothing to paste"
            self.status_timer = 20
            return
        }
        dec l = self.lines
        l = arr_insert(l, cb, self.cursor_row).result_unwrap_or(l)
        self.lines = l
        self.cursor_col = 0
        self.message = "Pasted line"
        self.dirty = true
        self.status_timer = 20
    }

    fn write_character(self, arr[string] key)
    {
        dec string ch = slice(
            key[0],
            5,
            len(key[0]).result_unwrap()
        ).result_unwrap()
        dec l = self.lines
        dec string current = l[self.cursor_row]
        dec string before = ""
        if (self.cursor_col > 0)
        {
            before = slice(current, 0, self.cursor_col).result_unwrap()
        }
        dec string after = ""
        if (self.cursor_col < len(current).result_unwrap())
        {
            after = slice(
                current,
                self.cursor_col,
                len(current).result_unwrap()
            ).result_unwrap()
        }
        l[self.cursor_row] = concat(before, concat(ch, after))
        self.lines = l
        self.cursor_col = self.cursor_col + 1
        self.message = ""
        self.dirty = true
        self.status_timer = clamp(self.status_timer - 1, 0, 20).result_unwrap_or(self.status_timer)
    }

    fn log_unknown_key(self, arr[string] key)
    {
        self.log = self.log.arr_push(key[0]).result_unwrap_or(self.log)
    }
}

/* helper functions:
 * 
 * used for coloring the rl
 * syntax highlighting
 *
 * might switch to maps instead for constants
 * and functions to support multiple languages */
fn color_keyword()
{
    term_fg("magenta")
}

fn color_type()
{
    term_fg("cyan")
}

fn color_string()
{
    term_fg("yellow")
}

fn color_number()
{
    term_fg("green")
}

fn color_comment()
{
    term_dim()
    term_fg("green")
}

fn color_op()
{
    term_fg("white")
}

fn color_linenum()
{
    term_fg("grey")
}

fn is_alnum(string ch) -> bool
{
    return is_alpha(ch) or is_numeric(ch)
}

fn is_op(string ch) -> bool
{
    return ch == "="
    or ch == "+"
    or ch == "-"
    or ch == "*"
    or ch == "/"
    or ch == "<"
    or ch == ">"
    or ch == "!"
}

fn kw_list() -> arr[string]
{
    return [
        "fn",
        "dec",
        "if",
        "else",
        "while",
        "for",
        "match",
        "return",
        "true",
        "false",
        "null",
        "get",
        "from",
        "in",
        "break",
        "continue",
        "and",
        "or",
    ]
}

fn type_list() -> arr[string]
{
    return [
        "int",
        "string",
        "bool",
        "float",
        "arr",
        "char",
        "byte",
        "void",
        "big",
        "small",
        "uint",
        "sbyte",
        "err",
        "error",
        "result",
        "ok",
    ]
}

// Colour a whole line, printing only the bytes inside the viewport
// [_from, to).
// 
// The scan deliberately still walks the ENTIRE line and clips only at print
// time, via print_span. Slicing the line to the viewport and highlighting that
// fragment breaks tokenization: a string opening at column 50, clipped to 60,
// arrives as `"llo world` and the scanner runs off the end of the fragment
// hunting a closing quote it can never find. The same applies to a `//`
// comment that starts off-screen. Clipping at the print instead means a token
// straddling the left edge still emits its tail in the correct colour, because
// the colour was chosen from the whole token.
// 
// `_from` rather than `from` because `from` is an RL keyword (`get ... from
// ...`) and cannot be a parameter name.
fn highlight(
    string line, arr[string] kws, arr[string] types, int _from, int to
    )
{
    dec int n = len(line).result_unwrap()
    if (n == 0)
    {
        return
    }

    dec int i = 0

    while (i < n)
    {
        dec string ch = slice(line, i, i + 1).result_unwrap()

        if (ch == "/" and i + 1 < n and slice(line, i + 1, i + 2).result_unwrap() == "/")
        {
            color_comment()
            print_span(line, i, n, _from, to)
            term_reset_color()
            i = n

        }
        else if (ch == "\"")
        {
            dec int j = i + 1
            dec int found = 0
            while (j < n and found == 0)
            {
                dec string sc = slice(line, j, j + 1).result_unwrap()
                if (sc == "\\")
                {
                    j = j + 2
                }
                else if (sc == "\"")
                {
                    j = j + 1
                    found = 1
                }
                else
                {
                    j = j + 1
                }
            }
            color_string()
            print_span(line, i, j, _from, to)
            term_reset_color()
            i = j

        }
        else if (is_numeric(ch))
        {
            dec int j = i + 1
            dec int scanning = 1
            while (j < n and scanning == 1)
            {
                dec string nc = slice(line, j, j + 1).result_unwrap()
                if (is_numeric(nc) or nc == ".")
                {
                    j = j + 1
                }
                else
                {
                    scanning = 0
                }
            }
            color_number()
            print_span(line, i, j, _from, to)
            term_reset_color()
            i = j

        }
        else if (is_alpha(ch))
        {
            dec int j = i + 1
            dec int scanning = 1
            while (j < n and scanning == 1)
            {
                dec string nc = slice(line, j, j + 1).result_unwrap()
                if (is_alnum(nc))
                {
                    j = j + 1
                }
                else
                {
                    scanning = 0
                }
            }
            dec string word = slice(line, i, j).result_unwrap()
            if (arr_contains(kws, word).result_unwrap())
            {
                color_keyword()
                print_span(line, i, j, _from, to)
                term_reset_color()
            }
            else if (arr_contains(types, word).result_unwrap())
            {
                color_type()
                print_span(line, i, j, _from, to)
                term_reset_color()
            }
            else
            {
                term_reset_color()
                print_span(line, i, j, _from, to)
            }
            i = j

        }
        else if (is_op(ch))
        {
            dec int j = i + 1
            dec int scanning = 1
            while (j < n and scanning == 1)
            {
                if (is_op(slice(line, j, j + 1).result_unwrap()))
                {
                    j = j + 1
                }
                else
                {
                    scanning = 0
                }
            }
            color_op()
            print_span(line, i, j, _from, to)
            term_reset_color()
            i = j

        }
        else
        {
            term_reset_color()
            print_span(line, i, i + 1, _from, to)
            i = i + 1
        }
    }
}

fn draw(Editor ed)
{

    dec arr[int] size = term_get_size().result_unwrap()
    dec int cols = size[0]
    dec int rows = size[1]
    dec int editor_rows = rows - 3
    dec int gutter_width = 7

    // The horizontal viewport: how many bytes of each line are visible to the
    // right of the gutter. view_cols() is the single definition of "text area
    // width", shared with the cursor-follow logic so the two cannot drift.
    dec int vc = view_cols()

    term_begin_sync()
    term_clear()

    // header
    term_move(0, 0)
    dec header_plain = concat("  rl-nano  |  ", ed.filename)
    dec header = concat(
        "\e[1;30;47m  rl-nano  |  ",
        ed.filename
    )
    dec int _pad = cols - len(header_plain).result_unwrap_or(0)
    if ed.dirty
    {
        _pad = _pad - 10
    }
    header = header.concat(" ".repeat(_pad))
    if ed.dirty
    {
        header = header.concat("Modified  ")
    }
    term_print(header)
    term_reset_attr()

    // end header
    // body
    dec int row = 0
    dec arr[string] kws = kw_list()
    dec arr[string] types = type_list()
    while (row < editor_rows)
    {
        term_move(0, row + 1)
        dec int abs_row = ed.scroll_top + row
        if (abs_row < len(ed.lines).result_unwrap())
        {
            color_linenum()
            dec string num_str = concat("", abs_row + 1)
            dec int pad_n = 6 - len(num_str).result_unwrap()
            dec int p = 0
            while (p < pad_n)
            {
                term_print(" ") p = p + 1
            }
            term_print(num_str)
            term_reset_color()
            term_print(" ")
            if ends_with(ed.filename, ".rl")
            {
                dec l = ed.lines
                highlight(
                    l[abs_row],
                    kws,
                    types,
                    ed.scroll_left,
                    ed.scroll_left + vc
                )
            }
            else
            {
                dec l = ed.lines
                print_window(
                    l[abs_row],
                    ed.scroll_left,
                    ed.scroll_left + vc
                )
            }
        }
        else
        {
            color_linenum()
            term_print("     ~ ")
            term_reset_color()
        }
        row = row + 1
    }

    // end body
    // status
    if ed.confirm_quit
    {
        term_move(0, rows - 2)
        dec m1_plain = "Save modified buffer?"
        dec m1 = "\e[1;30;47mSave modified buffer?"
        dec int _pad = cols - len(m1_plain).result_unwrap_or(0)
        term_print(m1.concat(" ".repeat(_pad)))

        dec m2_plain = " Y Yes   N No   C Cancel"
        dec m2 = "\e[30;47m Y\e[0;1;37m Yes  \e[1;30;47m N\e[0;1;37m No  \e[1;30;47m^C\e[0;1;37m Cancel"
        term_move(0, rows - 1)
        dec int _pad2 = cols - len(m2_plain).result_unwrap_or(0)
        term_print(m2.concat(" ".repeat(_pad2)))
    }
    else
    {
        term_move(0, rows - 2)
        dec plain_hint = "^S Save  ^X Quit  ^A Start of Line  ^E End of Line ^K Cut ^U Paste"
        dec _pad = cols - len(plain_hint).result_unwrap_or(0)
        dec string hint = "\e[1;30;47m^S\e[0;1;37m Save  \e[1;30;47m^X\e[0;1;37m Quit  \e[1;30;47m^A\e[0;1;37m Start of Line  \e[1;30;47m^E\e[0;1;37m End of line \e[1;30;47m^Y\e[0;1;37m PageUp \e[1;30;47m^V\e[0;1;37m PageDown  \e[1;30;47m^K\e[0;1;37m Cut  \e[1;30;47m^U\e[0;1;37m Paste"
        term_print(hint.concat(" ".repeat(_pad)))

        if ed.status_timer > 0
        {
            term_move(0, rows - 1)
            term_print(concat(
                ed.message,
                repeat(
                    " ",
                    cols - len(ed.message).result_unwrap_or(0)
                )
            ))
        }
        else
        {
            term_move(0, rows - 1)
            term_print(" ".repeat(cols))
        }
    }
    term_reset_attr()

    // status end
    // show cursor at correct place
    // 
    // `cursor_col - scroll_left` because cursor_col is an absolute offset into
    // the line while the terminal column is relative to the left edge of the
    // viewport. Without the subtraction the cursor sits vc columns to the right
    // of where the character it points at was actually drawn.
    term_move(
        ed.cursor_col - ed.scroll_left + gutter_width,
        ed.cursor_row - ed.scroll_top + 1
    )
    term_end_sync()
}

fn main()
{
    dec arr[string] Args = args()
    dec Editor ed = Editor
    {
        log: [""],
        filename: "untitled",
        lines: [""],
        cursor_row: 0,
        cursor_col: 0,
        message: "New file",
        running: true,
        scroll_left: 0,
        scroll_top: 0,
        pan_held: false,
        pan_col: 0,
        clipboard: "",
        dirty: false,
        confirm_quit: false,
        status_timer: 20,
    }

    match Args.len().result_unwrap()
    {
        0 =>
        {
        }

        1 =>
        {
            ed.filename = Args[0]
            if (path_exists(ed.filename))
            {
                ed.lines = split(
                    read_file(ed.filename).result_unwrap(),
                    "\n"
                )
                ed.message = format("Opened: {}", ed.filename)
            }
        }

        _ =>
        {
            println("usage nano <filename>")
            println(Args)
            exit(1)
        }
    }

    term_enter()
    term_hide_cursor()
    draw(ed)
    term_show_cursor()

    while (ed.running)
    {
        dec arr[string] key = term_read_key().result_unwrap()

        if ed.confirm_quit
        {
            match key[0]
            {
                "Char:y" => { ed.save_buffer(); ed.running = false }
                "Char:n" => { ed.running = false }
                "Ctrl:c" => { ed.confirm_quit = false; ed.message = "" }
                _ => {}
            }
        }
        else
        {
            match key[0]
            {
                "Resize" =>
                {
                    if key.len().result_unwrap_or(0) == 3
                    {
                        dec x = key[1].to_int().result_unwrap_or(0)
                        dec y = key[2].to_int().result_unwrap_or(0)
                        term_set_size(x, y)
                    }
                }
                "Ctrl:x" =>
                {
                    ed.stop()
                }

                "Ctrl:s" =>
                {
                    ed.save_buffer()
                }

                "Up" =>
                {
                    ed.move_cursor_up()
                }

                "Down" =>
                {
                    ed.move_cursor_down()
                }

                "PageUp" =>
                {
                    ed.move_page_up()
                }

                "PageDown" =>
                {
                    ed.move_page_down()
                }

                "Ctrl:y" =>
                {
                    ed.move_page_up()
                }

                "Ctrl:v" =>
                {
                    ed.move_page_down()
                }

                "Left" =>
                {
                    ed.move_cursor_to_left()
                }

                "Right" =>
                {
                    ed.move_cursor_to_right()
                }

                "Home" =>
                {
                    ed.go_to_start_of_line()
                }

                "End" =>
                {
                    ed.go_to_end_of_line()
                }

                "Ctrl:a" =>
                {
                    ed.go_to_start_of_line()
                }

                "Ctrl:e" =>
                {
                    ed.go_to_end_of_line()
                }

                // Cut / paste, nano's Ctrl+K and Ctrl+U. These are plain
                // control BYTES (0x0b and 0x15), not escape sequences, so the
                // decoder's Char arm hands them over as "Ctrl:k" / "Ctrl:u"
                // with no modifier handling involved.
                "Ctrl:k" =>
                {
                    ed.cut_line()
                }

                "Ctrl:u" =>
                {
                    ed.paste_line()
                }

                // Horizontal panning. These move the VIEWPORT, not the cursor,
                // so a long line can be inspected without losing the caret -
                // hence pan_held, which keeps ensure_cursor_visible from
                // dragging the view back until the cursor next moves.
                // 
                // Ctrl+Left / Ctrl+Right need the key decoder to preserve
                // modifiers: crossterm parses ESC [ 1 ; 5 D as Left+CONTROL, and
                // the C runtime's _rl_term_key_named turns that into "Ctrl:Left".
                "Ctrl:Left" =>
                {
                    ed.scroll_view_left()
                }

                "Ctrl:Right" =>
                {
                    ed.scroll_view_right()
                }

                "Ctrl:Home" =>
                {
                    ed.scroll_view_to_left_edge()
                }

                "Ctrl:End" =>
                {
                    ed.scroll_view_to_right_edge()
                }

                "Enter" =>
                {
                    ed.insert_newline()
                }

                "Backspace" =>
                {
                    ed.delete_char_behind()
                }

                "Delete" =>
                {
                    ed.delete_char_forward()
                }

                "Tab" =>
                {
                    ed.insert_tab()
                }

                _ =>
                {
                    if (starts_with(key[0], "Char:"))
                    {
                        ed.write_character(key)
                    }
                    else
                    {
                        ed.log_unknown_key(key)
                    }
                }
            }
        }

        // keep cursor visible, on both axes
        ed.ensure_cursor_visible()

        draw(ed)
    }

    term_reset_attr()
    term_reset_color()
    term_show_cursor()
    term_leave()
    println(ed.log)
}

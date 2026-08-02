get draw
get term_enter, term_leave from std::term
get term_hide_cursor, term_show_cursor from std::term
get term_read_key from std::term
get println, write_file, read_file from std::io
get path_exists from std::path
get split, slice, concat, format, join, starts_with from std::str
get arr_insert, arr_remove, arr_push, len from std::array
get args, exit from std::process

fn main() {
    dec arr[string] Args = args()

    dec string filename = "untitled"
    dec arr[string] lines   = [""]
    dec int cursor_row      = 0
    dec int cursor_col      = 0
    dec string message      = "New file"
    dec bool running        = true
    dec int scroll_top = 0

    match Args.len() {
        0 => {}

        1 => {
            filename = Args[0]
            if (path_exists(filename)) {
                lines   = split(read_file(filename)?, "\n")
            message = format("Opened: {}", filename)
            }
        }

       _ => {
            println("usage nano <filename>")
            exit(1)
        }
    }





    term_enter()
    term_hide_cursor()
    draw(lines, cursor_row, cursor_col, filename, message, scroll_top)
    term_show_cursor()

    while (running) {
        dec arr[string] key = term_read_key()?

        match key[0] {
            "Ctrl:q" => { running = false }

            "Ctrl:s" => {
                filename.write_file(lines.join("\n")?)
                message = "Saved: {}".format(filename)
            }

            "Up" => {
                if (cursor_row > 0) {
                    cursor_row = cursor_row - 1
                    dec int ll = len(lines[cursor_row])
                    if (cursor_col > ll) { cursor_col = ll }
                }
            }

            "Down" => {
                if (cursor_row < len(lines) - 1) {
                    cursor_row = cursor_row + 1
                    dec int ll = len(lines[cursor_row])
                    if (cursor_col > ll) { cursor_col = ll }
                }
            }

            "Left" => {
                if (cursor_col > 0) {
                    cursor_col = cursor_col - 1
                } else if (cursor_row > 0) {
                    cursor_row = cursor_row - 1
                    cursor_col = len(lines[cursor_row])
                }
            }

            "Right" => {
                dec int ll = len(lines[cursor_row])
                if (cursor_col < ll) {
                    cursor_col = cursor_col + 1
                } else if (cursor_row < len(lines) - 1) {
                    cursor_row = cursor_row + 1
                    cursor_col = 0
                }
            }

            "Home" => {
                cursor_col = 0
            }

            "End" => {
                cursor_col = len(lines[cursor_row])
            }

            "Enter" => {
                dec string current  = lines[cursor_row]
                dec string before   = ""
                if (cursor_col > 0) { before = slice(current, 0, cursor_col)? }
                dec string after    = ""
                if (cursor_col < len(current)) { after = slice(current, cursor_col, len(current))? }
                lines[cursor_row]   = before
                if (cursor_row + 1 < len(lines)) {
                    lines = arr_insert(lines, after, cursor_row + 1)?
                } else {
                    lines = arr_push(lines, after)?
                }
                cursor_row          = cursor_row + 1
                cursor_col          = 0
                message             = ""
            }

            "Backspace" => {
                if (cursor_col > 0) {
                    dec string current  = lines[cursor_row]
                    dec string before   = ""
                    if (cursor_col > 1) { before = slice(current, 0, cursor_col - 1)? }
                    dec string after    = ""
                    if (cursor_col < len(current)) { after = slice(current, cursor_col, len(current))? }
                    lines[cursor_row]   = concat(before, after)
                    cursor_col          = cursor_col - 1
                    message             = ""
                } else if (cursor_row > 0) {
                    dec int prev_len    = len(lines[cursor_row - 1])
                    dec string merged   = concat(lines[cursor_row - 1], lines[cursor_row])
                    lines[cursor_row - 1] = merged
                    lines               = arr_remove(lines, cursor_row)?
                    cursor_row          = cursor_row - 1
                    cursor_col          = prev_len
                    message             = ""
                }
            }

            "Delete" => {
                dec string current  = lines[cursor_row]
                dec int ll          = len(current)
                if (cursor_col < ll) {
                    dec string before   = ""
                    if (cursor_col > 0) { before = slice(current, 0, cursor_col)? }
                    dec string after    = ""
                    if (cursor_col + 1 < ll) { after = slice(current, cursor_col + 1, ll)? }
                    lines[cursor_row]   = concat(before, after)
                    message             = ""
                } else if (cursor_row < len(lines) - 1) {
                    dec string merged   = concat(lines[cursor_row], lines[cursor_row + 1])
                    lines[cursor_row]   = merged
                    lines               = arr_remove(lines, cursor_row + 1)?
                    message             = ""
                }
            }

            _ => {
                if (starts_with(key[0], "Char:")) {
                    dec string ch       = slice(key[0], 5, len(key))?
                    dec string current  = lines[cursor_row]
                    dec string before   = ""
                    if (cursor_col > 0) { before = slice(current, 0, cursor_col)? }
                    dec string after    = ""
                    if (cursor_col < len(current)) { after = slice(current, cursor_col, len(current))? }
                    lines[cursor_row]   = concat(before, concat(ch, after))
                    cursor_col          = cursor_col + 1
                    message             = ""
                }
            }
        }

        // keep cursor visible
        dec arr[int] sz      = term_get_size()?
        dec int editor_rows  = sz[1] - 2
        if (cursor_row < scroll_top) {
            scroll_top = cursor_row
        }
        if (cursor_row >= scroll_top + editor_rows) {
            scroll_top = cursor_row - editor_rows + 1
        }

        draw(lines, cursor_row, cursor_col, filename, message, scroll_top)
    }

    term_reset_attr()
    term_reset_color()
    term_show_cursor()
    term_leave()
}

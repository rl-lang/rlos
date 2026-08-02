get rl_highlight

get term_clear, term_move, term_print from std::term
get term_begin_sync, term_end_sync from std::term
get term_reverse, term_reset_attr from std::term
get term_set_fg, term_reset_color from std::term
get term_get_size from std::term
get concat, slice, starts_with, contains, ends_with from std::str
get arr_contains, len from std::array


fn draw(arr[string] lines, int cursor_row, int cursor_col, string filename, string message, int scroll_top) {

    dec arr[int] size     = term_get_size()?
    dec int cols          = size[0]
    dec int rows          = size[1]
    dec int editor_rows   = rows - 2
    dec int gutter_width  = 5

    term_begin_sync()
    term_clear()

    term_move(0, 0)
    term_reverse()
    dec string header = concat("  rl-nano  |  ", filename)
    term_print(header)
    dec int pad = cols - len(header)
    dec int i = 0
    while (i < pad) { term_print(" ") i = i + 1 }
    term_reset_attr()

    dec int row = 0
    dec arr[string] kws   = kw_list()
    dec arr[string] types = type_list()
    while (row < editor_rows) {
        term_move(0, row + 1)
        dec int abs_row = scroll_top + row
        if (abs_row < len(lines)) {
            color_linenum()
            dec string num_str = concat("", abs_row + 1)
            dec int pad_n = 4 - len(num_str)
            dec int p = 0
            while (p < pad_n) { term_print(" ") p = p + 1 }
            term_print(num_str)
            term_reset_color()
            term_print(" ")
            if ends_with(filename, ".rl") {
                highlight(lines[abs_row], kws, types)
            } else {
                term_print(lines[abs_row])
            }
        } else {
            color_linenum()
            term_print("   ~ ")
            term_reset_color()
        }
        row = row + 1
    }

    term_move(0, rows - 1)
    term_reverse()
    dec string status = concat("  ^S Save  ^Q Quit  |  ", message)
    term_print(status)
    dec int pad2 = cols - len(status)
    dec int j = 0
    while (j < pad2) { term_print(" ") j = j + 1 }
    term_reset_attr()

    term_move(cursor_col + gutter_width, cursor_row - scroll_top + 1)
    term_end_sync()
}

get theme

get term_set_fg, term_reset_color from std::term
get term_print from std::term
get slice, contains from std::str
get arr_contains, len from std::array

fn color_keyword() { term_set_fg(COL_KEYWORD[0], COL_KEYWORD[1], COL_KEYWORD[2]) }
fn color_type()    { term_set_fg(COL_TYPE[0],    COL_TYPE[1],    COL_TYPE[2])    }
fn color_string()  { term_set_fg(COL_STRING[0],  COL_STRING[1],  COL_STRING[2])  }
fn color_number()  { term_set_fg(COL_NUMBER[0],  COL_NUMBER[1],  COL_NUMBER[2])  }
fn color_comment() { term_set_fg(COL_COMMENT[0], COL_COMMENT[1], COL_COMMENT[2]) }
fn color_op()      { term_set_fg(COL_OP[0],      COL_OP[1],      COL_OP[2])      }
fn color_linenum() { term_set_fg(COL_LINENUM[0], COL_LINENUM[1], COL_LINENUM[2]) }

fn is_digit(string ch) -> bool {
    return ch == "0" or ch == "1" or ch == "2" or ch == "3" or ch == "4" or ch == "5" or ch == "6" or ch == "7" or ch == "8" or ch == "9"
}

fn is_alpha(string ch) -> bool {
    return ch == "a" or ch == "b" or ch == "c" or ch == "d" or ch == "e" or ch == "f" or ch == "g" or ch == "h" or ch == "i" or ch == "j" or ch == "k" or ch == "l" or ch == "m" or ch == "n" or ch == "o" or ch == "p" or ch == "q" or ch == "r" or ch == "s" or ch == "t" or ch == "u" or ch == "v" or ch == "w" or ch == "x" or ch == "y" or ch == "z" or ch == "A" or ch == "B" or ch == "C" or ch == "D" or ch == "E" or ch == "F" or ch == "G" or ch == "H" or ch == "I" or ch == "J" or ch == "K" or ch == "L" or ch == "M" or ch == "N" or ch == "O" or ch == "P" or ch == "Q" or ch == "R" or ch == "S" or ch == "T" or ch == "U" or ch == "V" or ch == "W" or ch == "X" or ch == "Y" or ch == "Z" or ch == "_"
}

fn is_alnum(string ch) -> bool {
    return is_alpha(ch) or is_digit(ch)
}

fn is_op(string ch) -> bool {
    return ch == "=" or ch == "+" or ch == "-" or ch == "*" or ch == "/" or ch == "<" or ch == ">" or ch == "!" or ch == "%" or ch == "^" or ch == "~"
}

fn kw_list() -> arr[string] {
    return ["fn", "dec", "if", "else", "while", "for", "match", "return",
     "true", "false", "null", "get", "from", "in", "break", "continue", "and", "or"]
}

fn type_list() -> arr[string] {
    return ["int", "string", "bool", "float", "arr", "char", "byte", "void"]
}

fn highlight(string line, arr[string] kws, arr[string] types) {
    dec int n = len(line)
    if (n == 0) { return }

    dec int i = 0

    while (i < n) {
        dec string ch = slice(line, i, i + 1)?

        if (ch == "/" and i + 1 < n and slice(line, i + 1, i + 2)? == "/") {
            color_comment()
            term_print(slice(line, i, n)?)
            term_reset_color()
            i = n

        } else if (ch == "\"") {
            dec int j = i + 1
            dec int found = 0
            while (j < n and found == 0) {
                dec string sc = slice(line, j, j + 1)?
                if (sc == "\\") {
                    j = j + 2
                } else if (sc == "\"") {
                    j = j + 1
                    found = 1
                } else {
                    j = j + 1
                }
            }
            color_string()
            term_print(slice(line, i, j)?)
            term_reset_color()
            i = j

        } else if (is_digit(ch)) {
            dec int j = i + 1
            dec int scanning = 1
            while (j < n and scanning == 1) {
                dec string nc = slice(line, j, j + 1)?
                if (is_digit(nc) or nc == ".") {
                    j = j + 1
                } else {
                    scanning = 0
                }
            }
            color_number()
            term_print(slice(line, i, j)?)
            term_reset_color()
            i = j

        } else if (is_alpha(ch)) {
            dec int j = i + 1
            dec int scanning = 1
            while (j < n and scanning == 1) {
                dec string nc = slice(line, j, j + 1)?
                if (is_alnum(nc)) {
                    j = j + 1
                } else {
                    scanning = 0
                }
            }
            dec string word = slice(line, i, j)?
            if (arr_contains(kws, word))? {
                color_keyword()
                term_print(word)
                term_reset_color()
            } else if (arr_contains(types, word))? {
                color_type()
                term_print(word)
                term_reset_color()
            } else {
                term_reset_color()
                term_print(word)
            }
            i = j

        } else if (is_op(ch)) {
            dec int j = i + 1
            dec int scanning = 1
            while (j < n and scanning == 1) {
                if (is_op(slice(line, j, j + 1)?)) {
                    j = j + 1
                } else {
                    scanning = 0
                }
            }
            color_op()
            term_print(slice(line, i, j)?)
            term_reset_color()
            i = j

        } else {
            term_reset_color()
            term_print(ch)
            i = i + 1
        }
    }
}

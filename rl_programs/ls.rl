get * from std::io
get * from std::fs
get * from std::process
get * from std::res
get * from std::str
get * from std::array
get std::len
get std::math::max

// options
dec list_current_dir_only = false
dec help = false
dec unknown_options = false
dec sorted = true
dec mark_dirs = true

// appends the ls directory marker, must run before the column width is measured
fn display_name(string name) -> string
{
    if mark_dirs
    {
        if std::fs::path_is_dir(name)
        {
            return name.concat("/")
        }
    }

    return name
}

// lays the names out in columns sized to fit the terminal,
// filled down each column then across, like ls
fn format_columns(arr[string] names, int term_cols, int gap) -> string
{
    dec total = names.len().result_unwrap_or(0)
    if total == 0
    {
        return ""
    }

    // cell pitch is the longest name plus the gap after it
    dec cell = gap
    for name in names
    {
        dec name_len = name.len().result_unwrap_or(0)
        cell = std::math::max(cell, name_len + gap).result_unwrap_or(cell)
    }

    dec width = term_cols
    if width <= 0
    {
        width = 80
    }
    if width < cell
    {
        width = cell
    }

    dec cols = width / cell
    if cols < 1
    {
        cols = 1
    }
    if cols > total
    {
        cols = total
    }

    dec rows = (total + cols - 1) / cols

    dec out = ""
    for r in arr_range(0, rows, 1).result_unwrap_or([])
    {
        dec line = ""
        for c in arr_range(0, cols, 1).result_unwrap_or([])
        {
            dec idx = c * rows + r
            if idx >= total
            {
                break
            }

            dec name = names[idx]
            dec name_len = name.len().result_unwrap_or(0)
            line = line.concat(name)

            // only pad when another cell follows on this row
            if c < cols - 1
            {
                if idx + rows < total
                {
                    line = line.concat(" ".repeat(cell - name_len))
                }
            }
        }

        out = out.concat(line).concat("\n")
    }

    return out
}

fn main()
{

    // first we capture the args
    dec args = args()

    // check if no args provided
    if args.len().result_unwrap_or(0) < 1
    {
        list_current_dir_only = true
    }

    // extract options
    dec arr[string] filtered_options = args.arr_filter(fn (string item) -> bool
    {
        return item.starts_with("-")
    })
    .result_unwrap_or_else(fn ()
    {
        eprintln("unexpected error while filtering options")
        exit(2)
        return
    })

    // strip options prefix
    .arr_map(fn (string item) -> string
    {
        if item.starts_with("--")
        {
            return item.strip_prefix("--").result_unwrap_or(item)
        }
        else
        {
            return item.strip_prefix("-").result_unwrap_or(item)
        }
    })
    .result_unwrap_or_else(fn ()
    {
        eprintln("unexpected error while stripping prefix from options")
        exit(2)
        return
    })

    // dedupe items
    .arr_unique()
    .result_unwrap_or_else(fn ()
    {
        eprintln("unexpected error while deduping options")
        exit(2)
        return
    })

    // set the correct flags
    for option in filtered_options
    {
        dec unknown_option = false
        match option
        {
            "h" => { help = true }
            "help" => { help = true }
            _ => { unknown_option = true; unknown_options = true }
        }

        if unknown_option
        {
            eprintln(format(
                "Unknown option: {}, use '-h' or '--help'",
                option
            ))
        }
    }

    // if unknown option(s) are provided print them then exit with code 3
    if unknown_options
    {
        exit(3)
    }

    // filter pathes
    dec arr[string] filtered_pathes = []
    for item in args
    {
        if item.starts_with("-")
        {
            continue
        }
        else
        {
            filtered_pathes = filtered_pathes.arr_push(item).result_unwrap_or(filtered_pathes)
        }
    }

    // check if there is any path (case: no path provided but options are provided)
    list_current_dir_only = filtered_pathes.len().result_unwrap_or(0) == 0

    // check if help option being used or not
    if help
    {
        println(
            "rl's ls tool\n\n",
            "usage:\n",
            "ls\t",
            "list the current directory items\n",
            "ls -h\n",
            "ls --h\t",
            "shows this help"
        )
        exit(0)
    }

    if list_current_dir_only
    {
        dec result[arr[string]] rpaths = list_dir(".")
        dec arr[string] paths = []

        if rpaths.std::res::is_err()
        {
            println("Error while listing directory items: ", std::res::result_unwrap_err(rpaths))
            exit(4)
        }
        else
        {
            paths = rpaths?
        }
        dec arr[string] corrected_pathes = []

        for path in paths
        {
            if path.starts_with("./")
            {
                path = path.strip_prefix("./").result_unwrap_or(path)
            }
            corrected_pathes = corrected_pathes.arr_push(path).result_unwrap_or(corrected_pathes)
        }

        dec arr[string] sorted_names = corrected_pathes

        if sorted
        {
            sorted_names = corrected_pathes.arr_sort_by(fn(string a, string b) -> int
            {
                dec a_len = a.len().result_unwrap_or(0)
                dec b_len = b.len().result_unwrap_or(0)
                return a_len - b_len
            }).result_unwrap_or_else(fn() {
                eprintln("Error while sorting items")
                exit(5)
                return
            })
        }

        dec arr[string] display = []
        for name in sorted_names
        {
            display = display.arr_push(display_name(name)).result_unwrap_or(display)
        }

        dec terminal_size = std::term::term_get_size().result_unwrap_or([80, 24])

        print(format_columns(display, terminal_size[0], 2))
    }
}

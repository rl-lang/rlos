get * from std::process
get * from std::io
get * from std::str
get * from std::array
get * from std::path
get * from std::res
get * from std::fs
get * from std::types
get * from std::collections
get std::len

// Last path component. list_dir() hands back bare names on some systems and
// full paths on others, and this host's /bin is a symlink into /usr/bin, so the
// result may not carry the prefix we asked for. strip_prefix()? would abort
// main() on the first mismatch - silently, since nothing catches it - which is
// how the shell used to die before it ever looked at its own arguments.
fn basename(string p) -> string
{
    dec int i = p.last_index_of("/")
    if i < 0
    {
        return p
    }
    return p.slice(i + 1, p.len()?).result_unwrap_or("")
}

// Drop one layer of matching surrounding quotes. popen(3) hands us a command
// line with the program name quoted ("xkbcomp" ...), and exec would otherwise
// look for a file whose name literally includes the quote characters.
fn unquote(string s) -> string
{
    dec int n = s.len()?
    if n >= 2
    {
        dec string f = s.slice(0, 1).result_unwrap_or("")
        dec string l = s.slice(n - 1, n).result_unwrap_or("")
        if f == "\"" and l == "\""
        {
            return s.slice(1, n - 1).result_unwrap_or("")
        }
        if f == "'" and l == "'"
        {
            return s.slice(1, n - 1).result_unwrap_or("")
        }
    }
    return s
}

fn main()
{

    // list items in /bin and /usr/bin directories
    dec arr[string] bin_p = list_dir("/bin/").result_unwrap_or([])
    dec arr[string] usr_bin_p = list_dir("/usr/bin/").result_unwrap_or([])
    dec set[string] bin_s = {}
    dec set[string] usr_bin_s = {}

    if !bin_p.arr_is_empty()?
    {
        for item in bin_p
        {
            bin_s = bin_s.set_add(basename(item))?
        }
    }
    if !usr_bin_p.arr_is_empty()?
    {
        for item in usr_bin_p
        {
            usr_bin_s = usr_bin_s.set_add(basename(item))?
        }
    }

    dec arr[string] Args = args()

    if !Args.arr_is_empty()? and Args[0] == "-c"
    {
        dec args = Args.arr_remove(0)?
        if args.arr_is_empty()?
        {
            println("missing command after '-c'")
            return
        }

        dec string cmdline = args[0]
        dec string cmd = ""
        dec string cmd_args = ""
        dec int first_ws = cmdline.index_of(" ")
        if first_ws < 0
        {
            cmd = cmdline
        }
        else
        {
            cmd = cmdline.slice(0, first_ws)?
            // popen(3) quotes the program name, and Xorg is what calls us:
            //   "xkbcomp" -w 1 "-R/usr/share/X11/xkb" -xkm "-" ... server-0.xkm
            // Without stripping those the exec looks for a file literally
            // named "xkbcomp" - quotes and all - and never finds it. Done here
            // rather than before the split, because the quotes are part of the
            // first word. The remaining arguments keep their quotes on purpose:
            // with_exec_fg tokenises them with shell_words, which is what
            // handles the -em1/-emp/-eml values that contain spaces.
            cmd = unquote(cmd)
            if !cmd.starts_with("/bin/") and !cmd.starts_with("./") and !cmd.starts_with("/")
            {
                if bin_s.set_contains(cmd)?
                {
                    cmd = "/bin/{}".format(cmd)
                }
                else if usr_bin_s.set_contains(cmd)?
                {
                    cmd = "/usr/bin/{}".format(cmd)
                }
            }
            cmd_args = cmdline.slice(first_ws + 1, cmdline.len()?)?
        }

        dec res = with_exec_fg(cmd, cmd_args)
        if res.is_err()
        {
            dec args_str = ""
            if !cmd_args.is_empty()
            {
                args_str = " with arguments {}".format(cmd_args)
            }
            println("failed to run command {}{}".format(cmd, args_str))
            exit(-1)
        }
        exit(res.result_unwrap_or(0))
    }

    dec string user = with_exec("/bin/whoami", "").result_unwrap_or("unknown").trim()
    dec string host = with_exec("/bin/hostname", "").result_unwrap_or("unknown").trim()
    dec bool running = true

    while (running)
    {
        dec string dir = cwd().result_unwrap_or("").path_filename()
        if dir.is_null() or dir.is_empty()
        {
            dir = "/"
        }

        dec string prompt = format(
            "\e[1;34m[\e[0;33m{}\e[32m@\e[33m{} \e[1;34m<\e[0;35m{}\e[1;34m>]\e[0;36m$\e[0m ",
            user,
            host,
            dir
        )

        dec string input = read(prompt)?.trim()

        if input == "exit"
        {
            running = false
        }
        else if input == ""
        {

        }
        else if input.starts_with("cd ")
        {
            dec arr[string] cmd = input.split(" ")
            dec string path = cmd[1]
            dec res = set_cwd(path)
            if res.std::res::is_err()
            {
                println(res.std::res::result_unwrap_err())
            }
        }
        else
        {
            dec string cmd = ""
            dec string args = ""
            dec int first_ws = input.index_of(" ")
            if first_ws < 0
            {
                cmd = input
            }
            else
            {
                cmd = input.slice(0, first_ws)?
                if !cmd.starts_with("/bin/") and !cmd.starts_with("./") and !cmd.starts_with("/")
                {
                    if bin_s.std::collections::set_contains(cmd)?
                    {
                        cmd = "/bin/{}".format(cmd)
                    }
                    else if usr_bin_s.std::collections::set_contains(cmd)?
                    {
                        cmd = "/usr/bin/{}".format(cmd)
                    }
                }
                args = input.slice(first_ws + 1, input.len()?)?
            }
            dec res = with_exec_fg(cmd, args)
            if res.std::res::is_err()
            {
                println(res.std::res::result_unwrap_err())
            }
        }
    }
}


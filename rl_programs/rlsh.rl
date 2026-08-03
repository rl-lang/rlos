get with_exec, with_exec_code, set_cwd, cwd, args, exit from std::process
get read, print, println from std::io
get split, trim, starts_with, slice, index_of, format, is_empty, join from std::str
get len, arr_is_empty, arr_remove from std::array
get path_filename from std::path
get result_unwrap_or, is_err, result_unwrap_err from std::res
get list_dir from std::fs
get is_null from std::types

fn main() {
    dec arr[string] bin_p = list_dir("/bin/").result_unwrap_or([])
    dec arr[string] usr_bin_p = list_dir("/usr/bin/").result_unwrap_or([])
    dec set[string] bin_s = {}
    dec set[string] usr_bin_s = {}

    if !bin_p.arr_is_empty()? {
        for item in bin_p {
            item = item.slice(5, item.len() - 1)?
            bin_s = bin_s.std::collections::set_add(item)?
        }
    }
    if !usr_bin_p.arr_is_empty()? {
        for item in bin_p {
            item = item.slice(5, item.len() - 1)?
            usr_bin_s = usr_bin_s.std::collections::set_add(item)?
        }
    }

    dec arr[string] Args = args()

    if !Args.arr_is_empty()? and Args[0] == "-c" {
        dec args = Args.arr_remove(0)?
        if args.arr_is_empty()? {
            println("missing command after '-c'")
            return
        }

        dec string cmdline = args[0]
        dec string cmd = ""
        dec string cmd_args = ""
        dec int first_ws = cmdline.index_of(" ")
        if first_ws < 0 {
            cmd = cmdline
        } else {
            cmd = cmdline.slice(0, first_ws)?
            if !cmd.starts_with("/bin/") and !cmd.starts_with("./") and !cmd.starts_with("/") {
                if bin_s.std::collections::set_contains(cmd)? {
                    cmd = "/bin/{}".format(cmd)
                } else if usr_bin_s.std::collections::set_contains(cmd)? {
                    cmd = "/usr/bin/{}".format(cmd)
                }
            }
            cmd_args = cmdline.slice(first_ws + 1, cmdline.len())?
        }

        dec res = with_exec_code(cmd, cmd_args)
        if res.is_err() {
            dec args_str = ""
            if !cmd_args.is_empty() {
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

    while (running) {
        dec string dir = cwd().result_unwrap_or("").path_filename()
        if dir.is_null() or dir.is_empty() {
            dir = "/"
        }

        dec string prompt = format("[{}@{} <{}>]$ ", user, host, dir)

        dec string input = read(prompt)?.trim()

        if input == "exit" {
            running = false
        } else if input == "" {

        } else if input.starts_with("cd ") {
            dec arr[string] cmd = input.split(" ")
            dec string path = cmd[1]
            dec res = set_cwd(path)
            if res.std::res::is_err() {
                println(res.std::res::result_unwrap_err())
            }
        } else {
            dec string cmd = ""
            dec string args = ""
            dec int first_ws = input.index_of(" ")
            if first_ws < 0 {
                cmd = input
            } else {
                cmd = input.slice(0, first_ws)?
                if !cmd.starts_with("/bin/") and !cmd.starts_with("./") and !cmd.starts_with("/") {
                    if bin_s.std::collections::set_contains(cmd)? {
                        cmd = "/bin/{}".format(cmd)
                    } else if usr_bin_s.std::collections::set_contains(cmd)? {
                        cmd = "/usr/bin/{}".format(cmd)
                    }
                }
                args = input.slice(first_ws + 1, input.len())?
            }
            dec res = with_exec_code(cmd, args)
            if res.std::res::is_err() {
                println(res.std::res::result_unwrap_err())
            }
        }
    }
}


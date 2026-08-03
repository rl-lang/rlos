get with_exec, with_exec_code, set_cwd, cwd, args, exit from std::process
get read, print, println from std::io
get split, trim, starts_with, slice, index_of, format, is_empty, join from std::str
get len, arr_is_empty, arr_remove from std::array
get path_filename from std::path
get result_unwrap_or, is_err, result_unwrap_err from std::res

fn main() {
    dec arr[string] Args = args()

    if !Args.arr_is_empty()? and Args[0] == "-c" {
        dec args = Args.arr_remove(0)?
        if args.arr_is_empty()? {
            println("missing command after '-c'")
            return
        }
        dec string cmd = args[0]
        args = args.arr_remove(0)?
        dec string args = args.join(" ")?
        dec res = with_exec_code(cmd, args)
        if res.is_err() {
            dec args_str = ""
            if !args.is_empty() {
                args_str = " with arguments {}".format(args)
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
        if dir == "" or dir.is_empty() { dir = "/"
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
                    cmd = "/bin/{}".format(cmd)
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


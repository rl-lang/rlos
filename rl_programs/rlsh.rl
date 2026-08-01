get with_exec, with_exec_code, set_cwd, cwd from std::process
get read, print, println from std::io
get split, trim, starts_with, slice, index_of, format from std::str
get len from std::array
get path_filename from std::path
get result_unwrap_or from std::res

dec string user = with_exec("/bin/rlwhoami", "").result_unwrap_or("unknown").trim()
dec string host = with_exec("/bin/rlhostname", "").result_unwrap_or("unknown").trim()
dec bool running = true

while (running) {
    dec string dir = cwd()?.path_filename()
    if dir == "" { dir = "/" }

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
        println(input)
        dec string cmd = ""
        dec string args = ""
        dec int first_ws = input.index_of(" ")
        if first_ws < 0{
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

get exec, exec_code, set_cwd, cwd from std::process
get read, print, println from std::io
get split, trim, starts_with, format from std::str
get len from std::array
get path_filename from std::path

dec string user = exec("whoami")?.trim()
dec string host = exec("hostname")?.trim()
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
        set_cwd(path)?
    } else {
        exec_code(input)?
    }
}

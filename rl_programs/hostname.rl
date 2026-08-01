get read_file, println from std::io
get result_unwrap_or from std::res
get trim from std::str

dec string name = read_file("/etc/hostname").result_unwrap_or("unknown")

println(name.trim())

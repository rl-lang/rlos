get * from std::io
get * from std::fs
get * from std::res
get * from std::str

dec string name = read_file("/etc/hostname").result_unwrap_or("unknown")

println(name.trim())

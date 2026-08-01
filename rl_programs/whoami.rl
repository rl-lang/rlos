get println, read_lines from std::io
get starts_with, split, trim from std::str

fn main () {
  dec string name = "unknown"
  dec string target_uid = ""

  dec result[arr[string]] rlines = read_lines("/proc/self/status")
  dec arr[string] lines = []

  if rlines.std::res::is_err() {
    println(name)
    return
  } else {
    lines = rlines?
  }

  for line in lines {
    if line.starts_with("Uid") {
      dec arr[string] broken_line = line.split(":")
      broken_line = broken_line[1].trim().split("\t")
      target_uid = broken_line[2].trim()
      break
    }
  }

  dec result[arr[string]] rlines = read_lines("/etc/passwd")
  dec arr[string] lines = []

  if rlines.std::res::is_err() {
    println(name)
    return
  } else {
    lines = rlines?
  }

  for line in lines {
    dec arr[string] broken_line = line.split(":")
    if broken_line[2] == target_uid {
       name = broken_line[0]
      break
    }
  }

  println(name.trim())
}

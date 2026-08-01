get read_lines, read_bytes, read_file, println from std::io
get args from std::process
get arr_is_empty, len from std::array
get format, split from std::str

fn main() {
  dec arr[string] Args = args()

  if !Args.arr_is_empty()? {
    dec int lines = Args[0].read_lines()?.len()
    dec int words = Args[0].read_file()?.split(" ").len()
    dec int bytes = Args[0].read_bytes()?.len()

    println(format("{}:\n\t|- {} line(s)\n\t|- {} word(s)\n\t|- {} byte(s)",
    Args[0], lines, words, bytes))
  } else {
    println("usage wc <file>")
  }
}

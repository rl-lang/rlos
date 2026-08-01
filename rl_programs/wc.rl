get read_lines, read_bytes, read_file, println from std::io
get args from std::process
get arr_is_empty, len from std::array
get format, split, is_empty, concat from std::str
get is_err from std::res

fn main() {
  dec arr[string] Args = args()

  if !Args.arr_is_empty()? {
    dec int lines = 0
    dec result[arr[string]] rlines = Args[0].read_lines() 

    if rlines.is_err() or (!rlines.is_err() and rlines?.arr_is_empty()?) {
      lines = -1
    } else {
      lines = rlines?.len()
    }

    dec int words = 0
    dec result[string] rwords = Args[0].read_file() 

    if rwords.is_err() or (!rwords.is_err() and rwords?.is_empty()) {
      words = -1
    } else {
      words = rwords?.split(" ").len()
    }

    dec int bytes = 0
    dec result[arr[byte]] rbytes = Args[0].read_bytes() 

    if rbytes.is_err() or (!rbytes.is_err() and rbytes?.arr_is_empty()?) {
      bytes = -1
    } else {
      bytes = rbytes?.len()
    }

    dec string output = "".concat(Args[0], ":")

    if lines != -1 {
      output = output.concat("\n\t|- {} line(s)".format(lines))
    }
    if words != -1 {
      output = output.concat("\n\t|- {} word(s)".format(words))
    }
    if bytes != -1 {
      output = output.concat("\n\t|- {} byte(s)".format(bytes))
    }
    println(output)
  } else {
    println("usage wc <file>")
  }
}

get println from std::io
get list_dir from std::fs

fn main() {
  dec result[arr[string]] rpaths = list_dir(".")
  dec arr[string] paths = []

  if rpaths.std::res::is_err() {
    println(std::res::result_unwrap_err(rpaths))
    return
  } else {
    paths = rpaths?
  }

  for path in paths {
      println(path)
  }
}

get delete_file, println, eprint from std::io
get path_exists from std::path
get args from std::process
get arr_is_empty from std::array
get is_err, result_unwrap_err from std::res

/*  Checklist:
        - [ ] -f, --force flag
        - [ ] -i, -I, --interactive flag
        - [ ] -r, -R, --recursive flag
        - [ ] -d, --dir flag
        - [ ] -v, --verbose flag
        - [ ] --help flag
        - [ ] --version flag
*/
fn main() {
    dec arr[string] Args = args()

    // check if user provided no items to delete
    // otherwise panic with error
    if Args.arr_is_empty()? {
        eprint("usage rm <file>\n")
    }

    // iterate over the pre-checked `Args`
    for item in Args {
        // check if item exists
        // otherwise prints the file doesn't exists
        if item.path_exists() {
            // checks for errors and prints them
            // without halting the execution
            dec res = item.delete_file()
            if res.is_err() {
                res.result_unwrap_err().println()
            }
        } else {
            println("rm: cannot remove '{}': No such file or directory".format(item))
        }
    }
}

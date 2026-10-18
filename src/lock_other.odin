#+build !linux
package mead

import "core:os"

// Other platforms need subprocess, path, and lock validation before mead supports them.
File_Lock :: struct {
	file: ^os.File,
}

lock_acquire :: proc(path: string) -> File_Lock {
	make_dirs(os.dir(path))
	f, err := os.open(path, {.Read, .Write, .Create})
	if err != nil {
		die("cannot open lock %q: %s", path, os.error_string(err))
	}
	return File_Lock{file = f}
}

lock_release :: proc(l: File_Lock) {
	os.close(l.file)
}

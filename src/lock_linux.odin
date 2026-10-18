#+build linux
package mead

import "core:os"
import "core:sys/linux"

// File locks guard shared cache entries and project state between concurrent mead processes.
File_Lock :: struct {
	file: ^os.File,
}

lock_acquire :: proc(path: string) -> File_Lock {
	make_dirs(os.dir(path))
	f, err := os.open(path, {.Read, .Write, .Create})
	if err != nil {
		die("cannot open lock %q: %s", path, os.error_string(err))
	}
	fd := linux.Fd(os.fd(f))
	if linux.flock(fd, {.EX, .NB}) != .NONE {
		info("waiting for lock %s", path)
		for linux.flock(fd, {.EX}) == .EINTR {}
	}
	return File_Lock{file = f}
}

lock_release :: proc(l: File_Lock) {
	linux.flock(linux.Fd(os.fd(l.file)), {.UN})
	os.close(l.file)
}

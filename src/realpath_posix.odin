#+build !windows
package mead

import "core:strings"
import "core:sys/posix"

// Resolves symlinks. Returns false if the path does not exist.
real_path :: proc(path: string) -> (string, bool) {
	cpath := strings.clone_to_cstring(path)
	buf: [posix.PATH_MAX]byte
	res := posix.realpath(cpath, raw_data(buf[:]))
	if res == nil {
		return "", false
	}
	return strings.clone(string(res)), true
}

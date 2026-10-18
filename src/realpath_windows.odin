#+build windows
package mead

import "core:os"

// Windows support is unvalidated. This resolves the path but not its links.
real_path :: proc(path: string) -> (string, bool) {
	if !os.exists(path) {
		return "", false
	}
	p, err := os.get_absolute_path(path, context.allocator)
	return p, err == nil
}

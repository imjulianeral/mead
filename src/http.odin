package mead

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

// A minimal libcurl binding. vendor:curl links mbedTLS on Linux, while system
// libcurl builds normally use the platform's TLS library.
foreign import libcurl "system:curl"

@(private = "file")
CURL :: struct {}
@(private = "file")
Curl_Slist :: struct {
	data: cstring,
	next: ^Curl_Slist,
}

@(private = "file")
CURLOPT_WRITEDATA :: 10001
@(private = "file")
CURLOPT_URL :: 10002
@(private = "file")
CURLOPT_USERAGENT :: 10018
@(private = "file")
CURLOPT_HTTPHEADER :: 10023
@(private = "file")
CURLOPT_HEADERDATA :: 10029
@(private = "file")
CURLOPT_FOLLOWLOCATION :: 52
@(private = "file")
CURLOPT_TIMEOUT :: 13
@(private = "file")
CURLOPT_CONNECTTIMEOUT :: 78
@(private = "file")
CURLOPT_LOW_SPEED_LIMIT :: 19
@(private = "file")
CURLOPT_LOW_SPEED_TIME :: 20
@(private = "file")
CURLOPT_WRITEFUNCTION :: 20011
@(private = "file")
CURLOPT_HEADERFUNCTION :: 20079
@(private = "file")
CURLINFO_RESPONSE_CODE :: 0x200000 + 2
@(private = "file")
CURL_GLOBAL_DEFAULT :: 3

@(private = "file", default_calling_convention = "c", link_prefix = "curl_")
foreign libcurl {
	global_init :: proc(flags: c.long) -> c.int ---
	easy_init :: proc() -> ^CURL ---
	easy_setopt :: proc(h: ^CURL, option: c.int, #c_vararg args: ..any) -> c.int ---
	easy_perform :: proc(h: ^CURL) -> c.int ---
	easy_getinfo :: proc(h: ^CURL, info: c.int, #c_vararg args: ..any) -> c.int ---
	easy_cleanup :: proc(h: ^CURL) ---
	easy_strerror :: proc(code: c.int) -> cstring ---
	slist_append :: proc(list: ^Curl_Slist, s: cstring) -> ^Curl_Slist ---
	slist_free_all :: proc(list: ^Curl_Slist) ---
}

HTTP_Response :: struct {
	status:  int,
	body:    string,
	// Header names are lower case.
	headers: map[string]string,
}

@(private = "file")
Capture :: struct {
	buf: [dynamic]byte,
	ctx: runtime.Context,
}

@(private = "file")
write_callback :: proc "c" (ptr: [^]byte, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	cap := (^Capture)(userdata)
	context = cap.ctx
	n := int(size * nmemb)
	append(&cap.buf, ..ptr[:n])
	return c.size_t(n)
}

@(private = "file")
curl_ready := false

// A nonzero timeout bounds the whole request, in seconds.
http_get :: proc(url: string, headers: []string, timeout := 0) -> (resp: HTTP_Response, err: string) {
	if !curl_ready {
		global_init(CURL_GLOBAL_DEFAULT)
		curl_ready = true
	}
	h := easy_init()
	if h == nil {
		return resp, "cannot initialize libcurl"
	}
	defer easy_cleanup(h)

	list: ^Curl_Slist
	for header in headers {
		list = slist_append(list, strings.clone_to_cstring(header))
	}
	defer slist_free_all(list)

	body := Capture{ctx = context}
	head := Capture{ctx = context}
	easy_setopt(h, CURLOPT_URL, strings.clone_to_cstring(url))
	easy_setopt(h, CURLOPT_USERAGENT, cstring("mead"))
	easy_setopt(h, CURLOPT_HTTPHEADER, list)
	easy_setopt(h, CURLOPT_FOLLOWLOCATION, c.long(1))
	easy_setopt(h, CURLOPT_CONNECTTIMEOUT, c.long(30))
	easy_setopt(h, CURLOPT_LOW_SPEED_LIMIT, c.long(1))
	easy_setopt(h, CURLOPT_LOW_SPEED_TIME, c.long(60))
	if timeout > 0 {
		easy_setopt(h, CURLOPT_CONNECTTIMEOUT, c.long(timeout))
		easy_setopt(h, CURLOPT_TIMEOUT, c.long(timeout))
	}
	easy_setopt(h, CURLOPT_WRITEFUNCTION, write_callback)
	easy_setopt(h, CURLOPT_WRITEDATA, rawptr(&body))
	easy_setopt(h, CURLOPT_HEADERFUNCTION, write_callback)
	easy_setopt(h, CURLOPT_HEADERDATA, rawptr(&head))

	code := easy_perform(h)
	if code != 0 {
		return resp, fmt.aprintf("request to %s failed: %s", url, string(easy_strerror(code)))
	}
	status: c.long
	easy_getinfo(h, CURLINFO_RESPONSE_CODE, &status)
	resp.status = int(status)
	resp.body = string(body.buf[:])
	// Redirects produce several header blocks; the last block wins.
	for line in strings.split_lines(string(head.buf[:])) {
		if strings.has_prefix(line, "HTTP/") {
			clear(&resp.headers)
			continue
		}
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			continue
		}
		name := strings.to_lower(strings.trim_space(line[:colon]))
		resp.headers[name] = strings.trim_space(line[colon + 1:])
	}
	return resp, ""
}

// GitHub REST access with response caching, pagination, and retry handling.

GitHub_Repo :: struct {
	owner: string,
	repo:  string,
}

parse_github_url :: proc(url: string) -> (gh: GitHub_Repo, ok: bool) {
	rest: string
	switch {
	case strings.has_prefix(url, "https://github.com/"):
		rest = url[len("https://github.com/"):]
	case strings.has_prefix(url, "ssh://git@github.com/"):
		rest = url[len("ssh://git@github.com/"):]
	case strings.has_prefix(url, "git@github.com:"):
		rest = url[len("git@github.com:"):]
	case:
		return gh, false
	}
	rest = strings.trim_suffix(strings.trim_right(rest, "/"), ".git")
	parts := strings.split(rest, "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return gh, false
	}
	return GitHub_Repo{parts[0], parts[1]}, true
}

GitHub_Asset :: struct {
	id:     i64,
	name:   string,
	size:   i64,
	digest: string,
	url:    string,
}

GitHub_Release :: struct {
	id:         i64,
	tag_name:   string,
	name:       string,
	prerelease: bool,
	draft:      bool,
	assets:     [dynamic]GitHub_Asset,
}

@(private = "file")
Cached_Response :: struct {
	etag: string `json:"etag"`,
	link: string `json:"link"`,
	body: string `json:"body"`,
}

@(private = "file")
github_headers :: proc() -> [dynamic]string {
	headers: [dynamic]string
	append(&headers, "Accept: application/vnd.github+json", "X-GitHub-Api-Version: 2022-11-28")
	token := get_env("GITHUB_TOKEN")
	if token == "" {
		token = get_env("GH_TOKEN")
	}
	if token != "" {
		append(&headers, strings.concatenate({"Authorization: Bearer ", token}))
	}
	return headers
}

// Fetches a GitHub API URL. Returns the body, the next page URL, and the status.
github_get :: proc(url: string, timeout := 0) -> (body: string, next: string, status: int, err: string) {
	cache_file := join(cache_root(), "http", strings.concatenate({sha256_hex(url), ".json"}))
	cached: Cached_Response
	has_cached := false
	if data, ok := read_file(cache_file); ok {
		has_cached = json.unmarshal_string(data, &cached) == nil
	}
	headers := github_headers()
	if has_cached && cached.etag != "" {
		append(&headers, strings.concatenate({"If-None-Match: ", cached.etag}))
	}

	resp: HTTP_Response
	for attempt := 0; ; attempt += 1 {
		herr: string
		resp, herr = http_get(url, headers[:], timeout)
		if herr != "" {
			return "", "", 0, herr
		}
		wait, retry := retry_delay(resp, attempt)
		if !retry || timeout > 0 {
			break
		}
		info("GitHub asked mead to wait %v before retrying", wait)
		time.sleep(wait)
	}

	switch resp.status {
	case 304:
		if has_cached {
			return cached.body, next_link(cached.link), 200, ""
		}
	case 200:
		write_file_atomic(cache_file, to_json(Cached_Response{
			etag = resp.headers["etag"],
			link = resp.headers["link"],
			body = resp.body,
		}))
		return resp.body, next_link(resp.headers["link"]), 200, ""
	case 404:
		return "", "", 404, ""
	}
	if resp.headers["x-ratelimit-remaining"] == "0" {
		reset := resp.headers["x-ratelimit-reset"]
		return "", "", resp.status, fmt.aprintf("the GitHub API rate limit is exhausted (resets at unix time %s); set GITHUB_TOKEN for a higher limit", reset)
	}
	return "", "", resp.status, fmt.aprintf("GitHub returned HTTP %d for %s", resp.status, url)
}

// Honors Retry-After and transient server errors with a bounded number of retries.
@(private = "file")
retry_delay :: proc(resp: HTTP_Response, attempt: int) -> (time.Duration, bool) {
	if attempt >= 3 {
		return 0, false
	}
	if after, has := resp.headers["retry-after"]; has && (resp.status == 403 || resp.status == 429 || resp.status == 503) {
		secs, ok := strconv.parse_int(after)
		if ok && secs <= 60 {
			return time.Duration(secs) * time.Second, true
		}
		return 0, false
	}
	if resp.status >= 500 {
		return time.Duration(1 << uint(attempt)) * time.Second, true
	}
	return 0, false
}

@(private = "file")
next_link :: proc(link: string) -> string {
	// Link: <https://api.github.com/...&page=2>; rel="next", <...>; rel="last"
	for part in strings.split(link, ",") {
		p := strings.trim_space(part)
		if !strings.contains(p, `rel="next"`) {
			continue
		}
		open := strings.index_byte(p, '<')
		close := strings.index_byte(p, '>')
		if open >= 0 && close > open {
			return p[open + 1:close]
		}
	}
	return ""
}

release_from_json :: proc(v: json.Value) -> (r: GitHub_Release) {
	obj, is_obj := v.(json.Object)
	if !is_obj {
		return
	}
	r.id = json_int(obj["id"])
	r.tag_name = json_str(obj["tag_name"])
	r.name = json_str(obj["name"])
	r.prerelease = json_bool(obj["prerelease"])
	r.draft = json_bool(obj["draft"])
	if assets, ok := obj["assets"].(json.Array); ok {
		for a in assets {
			ao, aok := a.(json.Object)
			if !aok {
				continue
			}
			append(&r.assets, GitHub_Asset{
				id = json_int(ao["id"]),
				name = json_str(ao["name"]),
				size = json_int(ao["size"]),
				digest = json_str(ao["digest"]),
				url = json_str(ao["browser_download_url"]),
			})
		}
	}
	return
}

json_str :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return s
}

json_bool :: proc(v: json.Value) -> bool {
	b, _ := v.(json.Boolean)
	return b
}

json_int :: proc(v: json.Value) -> i64 {
	#partial switch x in v {
	case json.Integer:
		return x
	case json.Float:
		return i64(x)
	}
	return 0
}

github_releases :: proc(gh: GitHub_Repo) -> (releases: [dynamic]GitHub_Release, err: string) {
	url := fmt.aprintf("https://api.github.com/repos/%s/%s/releases?per_page=100", gh.owner, gh.repo)
	for url != "" {
		body, next, status, gerr := github_get(url)
		if gerr != "" {
			return releases, gerr
		}
		if status == 404 {
			return releases, fmt.aprintf("GitHub repository %s/%s was not found (private repositories need GITHUB_TOKEN)", gh.owner, gh.repo)
		}
		v, perr := json.parse_string(body, parse_integers = true)
		if perr != nil {
			return releases, "GitHub returned invalid JSON"
		}
		if arr, ok := v.(json.Array); ok {
			for item in arr {
				append(&releases, release_from_json(item))
			}
		}
		url = next
	}
	return releases, ""
}

github_release_by_tag :: proc(gh: GitHub_Repo, tag: string) -> (release: GitHub_Release, err: string) {
	url := fmt.aprintf("https://api.github.com/repos/%s/%s/releases/tags/%s", gh.owner, gh.repo, tag)
	body, _, status, gerr := github_get(url)
	if gerr != "" {
		return release, gerr
	}
	if status == 404 {
		return release, fmt.aprintf("%s/%s has no GitHub release with tag %q (a Git tag alone needs `tag=` instead of `release=`)", gh.owner, gh.repo, tag)
	}
	v, perr := json.parse_string(body, parse_integers = true)
	if perr != nil {
		return release, "GitHub returned invalid JSON"
	}
	return release_from_json(v), ""
}

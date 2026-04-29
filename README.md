
![ymawky](http://i.imgur.com/INBvStO.png)

# Ymawky -- *web server in ARM assembly*
This is *ymawky*, a web server written entirely in ARM64 assembly. *ymawky* is a syscall-only, fork-per-connection web server written by hand, with no libc. While it is developed for MacOS, I've tried to make it as portable as possible -- *however*, it's likely you will still need to make some (hopefully minor) tweaks to get this to run on Linux/other Unix systems.

## Building
Run `make` to build.
Ensure there is a `www/` directory next to the `ymawky` executable. That's the document root where `ymawky` searches for files.
`GET` with an empty filename (`GET /`) will search for `www/index.html`, so you might want to make sure there's an `index.html` as well.

## Running
- `./ymawky` to start running the web server on `127.0.0.1:8080`.
- `./ymawky [port]` to start running the web server on `127.0.0.1:[port]`
- `./ymawky [literally-any-character-other-than-0-9]` to start running the web server on 127.0.0.1:8080 in debug mode. Debug mode disables forking, and makes ymawky only handle one request. (*I needed to do this because `lldb` wasn't letting me debug the children, ugh.*)

Unfortunately, while custom ports are supported, custom addresses are not. as of right now, ymawky can only run on `127.0.0.1`. This is solely because I haven't implemented it -- but if you'd like to consider this a safety feature, then I guess it could be intentional.

## What can it do?
Ymawky is a static-file web server. It doesn't support server-side code to generate content on-the-fly, or more advanced URL parsing, such as `/search?query=term`. That's not to say it's non-functional, though.
- Supported HTTP methods:
    - GET
    - PUT
    - DELETE
    - OPTIONS
    - HEAD
- Basic protection from slowloris-like Denial of Service attacks
- Decodes % hex encoding, eg, `%20` decodes to a space in filenames, and `%61` decodes to `a`
- Smart path traversal detection and prevention. Blocks `..` from traversing paths, while not disallowing multiple periods when they're part of a file:
  - `GET /../../../etc/passwd` -> `403 Forbidden`
  - `GET /ohwell...txt` -> `200 OK`
  - `GET /../src/ymawky.S` -> `403 Forbidden`
  - `GET /hehe..txt` -> `200 OK`
- Automatically prepends `www/` to requested files. `GET /index.html` will retrieve `www/index.html`
- Empty `GET /` requests default to `GET www/index.html`
- `PUT` requests support uploads of up to 1GiB, though this can be configured for larger files
- `PUT` is atomic due to writing to a temporary file then renaming, allowing concurrent `PUT` requests without leaving partially-written files
- `Content-Length:` parsing and verification in `PUT` requests
- MIME type detection, giving `Content-Type` in the response header with the corresponding MIME type

## "Safety"
This is a web server written entirely by-hand in ARM64 assembly as a fun project. It's probably got a lot of vulnerabilities I'm unaware of. However, I did do my best to make it safer. Here are some safety precautions ymawky takes.
- Rejects paths >= PATH_MAX (4096 bytes)
- Reject any paths that include path traversal -- `/../..`
- Reject any requests that do not contain a path within 16 bytes
- Confined to `www/`. Any path requested gets `www/` prepended to it
- Rejects any path containing symlinks, with O_NOFOLLOW_ANY
- PUT writes to a temporary file, `www/.ymawky_tmp_<pid>`. Upon successfully receiving the whole file, this temporary file is then renamed to the requested filename. This prevents partial or corrupted PUT requests from overwriting existing files.
- Reject any requests whose path starts with `www/.ymawky_tmp_`. This prevents someone from `GET`ing a temporary file, and prevents someone from sending `PUT /.ymawky_tmp_4533` or something.
- Must receive data within 10 seconds. If it's slower, the connection will close. If the entire header is not received within 10 seconds total, the connection will be closed. This is to prevent slowloris-like attacks.

## HTTP Status Codes
Ymawky currently supports and can reply with the following status codes:
- `200 OK`
- `201 Created`
- `204 No Content`
- `400 Bad Request`
- `403 Forbidden`
- `404 Not Found`
- `408 Request Timeout`
- `409 Conflict`
- `411 Length Required`
- `413 Content Too Large`
- `414 URI Too Long`
- `418 I'm a teapot`
- `431 Request Header Fields Too Large`
- `500 Internal Server Error`
- `501 Not Implemented`
- `507 Insufficient Storage`

## MIME Types
MIME types are detected by analyzing the file extension. The following MIME types are recognized:
- `.html` -> `text/html; charset=utf-8`
- `.css` -> `text/css; charset=utf-8`
- `.js` -> `text/javascript; charset=utf-8`
- `.json` -> `application/json`
- `.png` -> `image/png`
- `.jpg` -> `image/jpeg`
- `.jpeg` -> `image/jpeg`
- `.gif` -> `image/gif`
- `.svg` -> `image/svg+xml`
- `.ico` -> `image/x-icon`
- `.webp` -> `image/webp`
- `.txt` -> `text/plain; charset=utf-8`
- `.pdf` -> `application/pdf`
- `.woff2` -> `font/woff2`
- `.xml` -> `text/xml; charset=utf-8`

### Special Thanks:
- *Bob Johnson*
- *Bob Johnson's Therapist*

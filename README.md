# Downloads

The `Downloads` package provides a single function, `download`, which provides
cross-platform, multi-protocol, in-process download functionality implemented
with [libcurl](https://curl.haxx.se/libcurl/). It uses libcurl's multi-handle
callback API to present a Julian API: `download(url)` blocks the task in which
it occurs but yields to Julia's scheduler, allowing arbitrarily many tasks to
download URLs concurrently and efficiently. As of Julia 1.6, this package is a
standard library that is included with Julia, but this package can be used with
Julia 1.3 through 1.5 as well.

## API

```jl
download(url, [ output = tempfile() ]; [ headers ]) -> output
```
* `url     :: AbstractString`
* `output  :: Union{AbstractString, AbstractCmd, IO}`
* `headers :: Union{AbstractVector, AbstractDict}`

Download a file from the given url, saving it to `output` or if not specified,
a temporary path. The `output` can also be an `IO` handle, in which case the
body of the response is streamed to that handle and the handle is returned. If
`output` is a command, the command is run and output is sent to it on stdin.

If the `headers` keyword argument is provided, it must be a vector or dictionary
whose elements are all pairs of strings. These pairs are passed as headers when
downloading URLs with protocols that supports them, such as HTTP/S.

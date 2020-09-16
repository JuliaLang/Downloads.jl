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
download(url, [ path = tempfile() ]; [ headers ]) -> path
download(url, io; [ headers ]) -> io
```

- `url     :: AbstractString`
- `path    :: AbstractString`
- `io      :: IO`
- `headers :: Union{AbstractVector, AbstractDict}`

Download a file from the given url, saving it to the location `path`, or if not
specified, a temporary path. Returns the path of the downloaded file. If the
second argument is an IO handle instead of a path, the body of the downloaded
URL is written to the handle instead and the handle is returned.

If the `headers` keyword argument is provided, it must be a vector or dictionary
whose elements are all pairs of strings. These pairs are passed as headers when
downloading URLs with protocols that supports them, such as HTTP/S.

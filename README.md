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

### download

```jl
    download(url, [ output = tempfile() ];
        [ headers = <none>, ]
        [ progress = <none>, ]
        [ downloader = <default downloader>, ]
        [ verbose = false, ]
    ) -> output
```
* `url        :: AbstractString`
* `output     :: Union{AbstractString, AbstractCmd, IO}`
* `headers    :: Union{AbstractVector, AbstractDict}`
* `progress   :: (total::Integer, now::Integer) --> Any`
* `downloader :: Downloader`
* `verbose    :: Bool`

Download a file from the given url, saving it to `output` or if not specified, a
temporary path. The `output` can also be an `IO` handle, in which case the body
of the response is streamed to that handle and the handle is returned. If
`output` is a command, the command is run and output is sent to it on stdin.

If the `headers` keyword argument is provided, it must be a vector or dictionary
whose elements are all pairs of strings. These pairs are passed as headers when
downloading URLs with protocols that supports them, such as HTTP/S.

If the `downloader` keyword argument is provided, it must be a `Downloader`
object. Resources and connections will be shared between downloads performed by
the same `Downloader` and cleaned up automatically when the object is garbage
collected or there have been no downloads performed with it for a grace period.
See [`Downloader`](@ref) for more info about configuration and usage.

If the `progress` keyword argument is provided, it must be a callback funtion
which will be called whenever there are updates about the size and status of the
ongoing download. The callback must take two integer arguments: `total` and
`now` which are the total size of the download in bytes, and the number of bytes
which have been downloaded so far. Note that `total` starts out as zero and
remains zero until the server gives an indiation of the total size of the
download (e.g. with a `Content-Length` header), which may never happen. So a
well-behaved progress callback should handle a total size of zero gracefully.

If the `verbose` optoin is set to true, `libcurl`, which is used to implement
the download functionality will print debugging information to `stderr`.

### Downloader

```jl
    Downloader(; [ grace::Real = 30 ])
```

`Downloader` objects are used to perform individual `download` operations.
Connections, lookups and other resources are shared within a `Downloader`. These
connections and resources are cleaned up when the `Downloader` is garbage
collected or a configurable grace period (default: 30 seconds) after the last
time the `Downloader` was used to download anything. If the grace period is set
to zero, all resources will be cleaned up as soon as there are no associated
downloads in progress. If the grace period is set to `Inf` then resources are
not cleaned up until the `Downloader` object is garbage collected.

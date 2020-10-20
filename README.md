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
    [ downloader = <default downloader>, ]
    [ headers = <none>, ]
    [ method = "GET", ]
    [ progress = <none>, ]
    [ verbose = false, ]
) -> output
```
* `url        :: AbstractString`
* `output     :: Union{AbstractString, AbstractCmd, IO}`
* `downloader :: Downloader`
* `headers    :: Union{AbstractVector, AbstractDict}`
* `method     :: AbstractString`
* `progress   :: (total::Integer, now::Integer) --> Any`
* `verbose    :: Bool`

Download a file from the given url, saving it to `output` or if not specified, a
temporary path. The `output` can also be an `IO` handle, in which case the body
of the response is streamed to that handle and the handle is returned. If
`output` is a command, the command is run and output is sent to it on stdin.

If the `downloader` keyword argument is provided, it must be a `Downloader`
object. Resources and connections will be shared between downloads performed by
the same `Downloader` and cleaned up automatically when the object is garbage
collected or there have been no downloads performed with it for a grace period.
See [`Downloader`](@ref) for more info about configuration and usage.

If the `headers` keyword argument is provided, it must be a vector or dictionary
whose elements are all pairs of strings. These pairs are passed as headers when
downloading URLs with protocols that supports them, such as HTTP/S.

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

### request

```jl
request(url;
    [ output = devnull, ]
    [ downloader = <default downloader>, ]
    [ headers = <none>, ]
    [ method = "GET", ]
    [ progress = <none>, ]
    [ verbose = false, ]
) -> output
```
* `url        :: AbstractString`
* `output     :: Union{AbstractString, AbstractCmd, IO}`
* `downloader :: Downloader`
* `headers    :: Union{AbstractVector, AbstractDict}`
* `method     :: AbstractString`
* `progress   :: (dl_total, dl_now, ul_total, ul_now) --> Any`
* `verbose    :: Bool`

Make a request to the given url, returning a [`Response`](@ref) object capturing
the status, headers and other information about the response. The body of the
reponse is written to `output` if specified and discarded otherwise.

Other options are the same as for `download` except for `progress` which must be
a function accepting four integer arguments (rather than two), indicating both
upload and download progress.

### Response

```jl
struct Response
    url     :: String
    status  :: Int
    message :: String
    headers :: Vector{Pair{String,String}}
end
```

`Response` is a type capturing the properties the response to a request as an
object. It has the following fields:

- `url`: the URL that was ultimately requested after following redirects
- `status`: the status code of the response, indicating success, failure, etc.
- `message`: a textual message describing the nature of the response
- `headers`: any headers that were returned with the response

The meaning and availability of some of these responses depends on the protocol
used for the request. For many protocols, including HTTP/S and S/FTP, a 2xx
status code indicates a successful response. For responses in protocols that do
not support headers, the headers vector will be empty. HTTP/2 does not include a
status message, only a status code, so the message will be empty.

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

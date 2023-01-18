# Downloads

[![Build Status](https://github.com/JuliaLang/Downloads.jl/workflows/CI/badge.svg)](https://github.com/JuliaLang/Downloads.jl/actions)
[![Codecov](https://codecov.io/gh/JuliaLang/Downloads.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaLang/Downloads.jl)

The `Downloads` package provides a single function, `download`, which provides
cross-platform, multi-protocol, in-process download functionality implemented
with [libcurl](https://curl.haxx.se/libcurl/). It uses libcurl's multi-handle
callback API to present a Julian API: `download(url)` blocks the task in which
it occurs but yields to Julia's scheduler, allowing arbitrarily many tasks to
download URLs concurrently and efficiently. As of Julia 1.6, this package is a
standard library that is included with Julia, but this package can be used with
Julia 1.3 through 1.5 as well.

## API

The public API of `Downloads` consists of three functions and three types:

- `download` — download a file from a URL, erroring if it can't be downloaded
- `request` — request a URL, returning a `Response` object indicating success
- `default_downloader!` - set the default `Downloader` object
- `Response` — a type capturing the status and other metadata about a request
- `RequestError` — an error type thrown by `download` and `request` on error
- `Downloader` — an object encapsulating shared resources for downloading

### download

```jl
download(url, [ output = tempname() ];
    [ method = "GET", ]
    [ headers = <none>, ]
    [ timeout = <none>, ]
    [ progress = <none>, ]
    [ verbose = false, ]
    [ debug = <none>, ]
    [ downloader = <default>, ]
) -> output
```
- `url        :: AbstractString`
- `output     :: Union{AbstractString, AbstractCmd, IO}`
- `method     :: AbstractString`
- `headers    :: Union{AbstractVector, AbstractDict}`
- `timeout    :: Real`
- `progress   :: (total::Integer, now::Integer) --> Any`
- `verbose    :: Bool`
- `debug      :: (type, message) --> Any`
- `downloader :: Downloader`

Download a file from the given url, saving it to `output` or if not specified, a
temporary path. The `output` can also be an `IO` handle, in which case the body
of the response is streamed to that handle and the handle is returned. If
`output` is a command, the command is run and output is sent to it on stdin.

If the `downloader` keyword argument is provided, it must be a `Downloader`
object. Resources and connections will be shared between downloads performed by
the same `Downloader` and cleaned up automatically when the object is garbage
collected or there have been no downloads performed with it for a grace period.
See `Downloader` for more info about configuration and usage.

If the `headers` keyword argument is provided, it must be a vector or dictionary
whose elements are all pairs of strings. These pairs are passed as headers when
downloading URLs with protocols that supports them, such as HTTP/S.

The `timeout` keyword argument specifies a timeout for the download in seconds,
with a resolution of milliseconds. By default no timeout is set, but this can
also be explicitly requested by passing a timeout value of `Inf`.

If the `progress` keyword argument is provided, it must be a callback function
which will be called whenever there are updates about the size and status of the
ongoing download. The callback must take two integer arguments: `total` and
`now` which are the total size of the download in bytes, and the number of bytes
which have been downloaded so far. Note that `total` starts out as zero and
remains zero until the server gives an indication of the total size of the
download (e.g. with a `Content-Length` header), which may never happen. So a
well-behaved progress callback should handle a total size of zero gracefully.

If the `verbose` option is set to true, `libcurl`, which is used to implement
the download functionality will print debugging information to `stderr`. If the
`debug` option is set to a function accepting two `String` arguments, then the
verbose option is ignored and instead the data that would have been printed to
`stderr` is passed to the `debug` callback with `type` and `message` arguments.
The `type` argument indicates what kind of event has occurred, and is one of:
`TEXT`, `HEADER IN`, `HEADER OUT`, `DATA IN`, `DATA OUT`, `SSL DATA IN` or `SSL
DATA OUT`. The `message` argument is the description of the debug event.

### request

```jl
request(url;
    [ input = <none>, ]
    [ output = <none>, ]
    [ method = input ? "PUT" : output ? "GET" : "HEAD", ]
    [ headers = <none>, ]
    [ timeout = <none>, ]
    [ progress = <none>, ]
    [ verbose = false, ]
    [ debug = <none>, ]
    [ throw = true, ]
    [ downloader = <default>, ]
) -> Union{Response, RequestError}
```
- `url        :: AbstractString`
- `input      :: Union{AbstractString, AbstractCmd, IO}`
- `output     :: Union{AbstractString, AbstractCmd, IO}`
- `method     :: AbstractString`
- `headers    :: Union{AbstractVector, AbstractDict}`
- `timeout    :: Real`
- `progress   :: (dl_total, dl_now, ul_total, ul_now) --> Any`
- `verbose    :: Bool`
- `debug      :: (type, message) --> Any`
- `throw      :: Bool`
- `downloader :: Downloader`

Make a request to the given url, returning a `Response` object capturing the
status, headers and other information about the response. The body of the
response is written to `output` if specified and discarded otherwise. For HTTP/S
requests, if an `input` stream is given, a `PUT` request is made; otherwise if
an `output` stream is given, a `GET` request is made; if neither is given a
`HEAD` request is made. For other protocols, appropriate default methods are
used based on what combination of input and output are requested. The following
options differ from the `download` function:

- `input` allows providing a request body; if provided default to `PUT` request
- `progress` is a callback taking four integers for upload and download progress
- `throw` controls whether to throw or return a `RequestError` on request error

Note that unlike `download` which throws an error if the requested URL could not
be downloaded (indicated by non-2xx status code), `request` returns a `Response`
object no matter what the status code of the response is. If there is an error
with getting a response at all, then a `RequestError` is thrown or returned.

### default_downloader!

```jl
    default_downloader!(
        downloader = <none>
    ) 
```
- `downloader :: Downloader`

Set the default `Downloader`. If no argument is provided, resets the default downloader 
so that a fresh one is created the next time the default downloader is needed.

### Response

```jl
struct Response
    proto   :: String
    url     :: String
    status  :: Int
    message :: String
    headers :: Vector{Pair{String,String}}
end
```
`Response` is a type capturing the properties of a successful response to a
request as an object. It has the following fields:

- `proto`: the protocol that was used to get the response
- `url`: the URL that was ultimately requested after following redirects
- `status`: the status code of the response, indicating success, failure, etc.
- `message`: a textual message describing the nature of the response
- `headers`: any headers that were returned with the response

The meaning and availability of some of these responses depends on the protocol
used for the request. For many protocols, including HTTP/S and S/FTP, a 2xx
status code indicates a successful response. For responses in protocols that do
not support headers, the headers vector will be empty. HTTP/2 does not include a
status message, only a status code, so the message will be empty.

### RequestError

```jl
struct RequestError <: ErrorException
    url      :: String
    code     :: Int
    message  :: String
    response :: Response
end
```
`RequestError` is a type capturing the properties of a failed response to a
request as an exception object:

- `url`: the original URL that was requested without any redirects
- `code`: the libcurl error code; `0` if a protocol-only error occurred
- `message`: the libcurl error message indicating what went wrong
- `response`: response object capturing what response info is available

The same `RequestError` type is thrown by `download` if the request was
successful but there was a protocol-level error indicated by a status code that
is not in the 2xx range, in which case `code` will be zero and the `message`
field will be the empty string. The `request` API only throws a `RequestError`
if the libcurl error `code` is non-zero, in which case the included `response`
object is likely to have a `status` of zero and an empty message. There are,
however, situations where a curl-level error is thrown due to a protocol error,
in which case both the inner and outer code and message may be of interest.

### Downloader

```jl
Downloader(; [ grace::Real = 30 ])
```
`Downloader` objects are used to perform individual `download` operations.
Connections, name lookups and other resources are shared within a `Downloader`.
These connections and resources are cleaned up after a configurable grace period
(default: 30 seconds) since anything was downloaded with it, or when it is
garbage collected, whichever comes first. If the grace period is set to zero,
all resources will be cleaned up immediately as soon as there are no more
ongoing downloads in progress. If the grace period is set to `Inf` then
resources are not cleaned up until `Downloader` is garbage collected.


## Mutual TLS using Downloads

```jl
using Downloads: Curl, Downloader, download

easy_hook = (easy, info) -> begin
    Curl.setopt(easy, Curl.CURLOPT_SSLKEY,  "client.key")
    Curl.setopt(easy, Curl.CURLOPT_SSLCERT, "client.crt")
end
downloader = Downloader()
downloader.easy_hook = easy_hook

download(url; downloader)
```

Here, client.key and client.crt are the private and public keys for the client.

It’s also possible currently to make the default downloader use that hook by putting it into Downloads.EASY_HOOK. Here’s an example:

```jl
using Downloads: Downloads, Curl, download

Downloads.EASY_HOOK[] = (easy, info) -> begin
    Curl.setopt(easy, Curl.CURLOPT_SSLKEY,  "client.key")
    Curl.setopt(easy, Curl.CURLOPT_SSLCERT, "client.crt")
end

download(url)
```

There is no difference between usage on Windows, MacOS, and Linux.

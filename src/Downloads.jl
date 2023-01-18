"""
The `Downloads` module exports a function [`download`](@ref), which provides cross-platform, multi-protocol,
in-process download functionality implemented with [libcurl](https://curl.haxx.se/libcurl/).   It is used
for the `Base.download` function in Julia 1.6 or later.

More generally, the module exports functions and types that provide lower-level control and diagnostic information
for file downloading:
- [`download`](@ref) — download a file from a URL, erroring if it can't be downloaded
- [`request`](@ref) — request a URL, returning a `Response` object indicating success
- [`Response`](@ref) — a type capturing the status and other metadata about a request
- [`RequestError`](@ref) — an error type thrown by `download` and `request` on error
- [`Downloader`](@ref) — an object encapsulating shared resources for downloading
"""
module Downloads

using Base.Experimental: @sync
using NetworkOptions
using ArgTools

include("Curl/Curl.jl")
using .Curl

export download, request, Downloader, Response, RequestError, default_downloader!

## public API types ##

"""
    Downloader(; [ grace::Real = 30 ])

`Downloader` objects are used to perform individual `download` operations.
Connections, name lookups and other resources are shared within a `Downloader`.
These connections and resources are cleaned up after a configurable grace period
(default: 30 seconds) since anything was downloaded with it, or when it is
garbage collected, whichever comes first. If the grace period is set to zero,
all resources will be cleaned up immediately as soon as there are no more
ongoing downloads in progress. If the grace period is set to `Inf` then
resources are not cleaned up until `Downloader` is garbage collected.
"""
mutable struct Downloader
    multi::Multi
    ca_roots::Union{String, Nothing}
    easy_hook::Union{Function, Nothing}

    Downloader(multi::Multi) = new(multi, get_ca_roots(), EASY_HOOK[])
end
Downloader(; grace::Real=30) = Downloader(Multi(grace_ms(grace)))

function grace_ms(grace::Real)
    grace < 0 && throw(ArgumentError("grace period cannot be negative: $grace"))
    grace <= typemax(UInt64) ÷ 1000 ? round(UInt64, 1000*grace) : typemax(UInt64)
end

function easy_hook(downloader::Downloader, easy::Easy, info::NamedTuple)
    downloader.easy_hook !== nothing && downloader.easy_hook(easy, info)
end

get_ca_roots() = Curl.SYSTEM_SSL ? ca_roots() : ca_roots_path()

function set_ca_roots(downloader::Downloader, easy::Easy)
    ca_roots = downloader.ca_roots
    ca_roots !== nothing && set_ca_roots_path(easy, ca_roots)
end

const DOWNLOAD_LOCK = ReentrantLock()
const DOWNLOADER = Ref{Union{Downloader, Nothing}}(nothing)

"""
`EASY_HOOK` is a modifable global hook to used as the default `easy_hook` on 
new `Downloader` objects. This supplies a mechanism to set options for the 
`Downloader` via `Curl.setopt`

It is expected to be function taking two arguments: an `Easy` struct and an 
`info` NamedTuple with names `url`, `method` and `headers`. 
"""
const EASY_HOOK = Ref{Union{Function, Nothing}}(nothing)

"""
    struct Response
        proto   :: String
        url     :: String
        status  :: Int
        message :: String
        headers :: Vector{Pair{String,String}}
    end

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
"""
struct Response
    proto   :: Union{String, Nothing}
    url     :: String # redirected URL
    status  :: Int
    message :: String
    headers :: Vector{Pair{String,String}}
end

Curl.status_ok(response::Response) = status_ok(response.proto, response.status)

"""
    struct RequestError <: ErrorException
        url      :: String
        code     :: Int
        message  :: String
        response :: Response
    end

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
"""
struct RequestError <: Exception
    url      :: String # original URL
    code     :: Int
    message  :: String
    response :: Response
end

function Base.showerror(io::IO, err::RequestError)
    print(io, "RequestError: $(error_message(err)) while requesting $(err.url)")
end

function error_message(err::RequestError)
    errstr = err.message
    status = err.response.status
    message = err.response.message
    status_re = Regex(status == 0 ? "" : "\\b$status\\b")

    err.code == Curl.CURLE_OK &&
        return isempty(message) ? "Error status $status" :
            contains(message, status_re) ? message :
                "$message (status $status)"

    isempty(message) && !isempty(errstr) &&
        return status == 0 ? errstr : "$errstr (status $status)"

    isempty(message) && (message = "Status $status")
    isempty(errstr)  && (errstr = "curl error $(err.code)")

    !contains(message, status_re) && !contains(errstr, status_re) &&
        (errstr = "status $status; $errstr")

    return "$message ($errstr)"
end

## download API ##

"""
    download(url, [ output = tempname() ];
        [ method = "GET", ]
        [ headers = <none>, ]
        [ timeout = <none>, ]
        [ progress = <none>, ]
        [ verbose = false, ]
        [ debug = <none>, ]
        [ downloader = <default>, ]
    ) -> output

        url        :: AbstractString
        output     :: Union{AbstractString, AbstractCmd, IO}
        method     :: AbstractString
        headers    :: Union{AbstractVector, AbstractDict}
        timeout    :: Real
        progress   :: (total::Integer, now::Integer) --> Any
        verbose    :: Bool
        debug      :: (type, message) --> Any
        downloader :: Downloader

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
"""
function download(
    url        :: AbstractString,
    output     :: Union{ArgWrite, Nothing} = nothing;
    method     :: Union{AbstractString, Nothing} = nothing,
    headers    :: Union{AbstractVector, AbstractDict} = Pair{String,String}[],
    timeout    :: Real = Inf,
    progress   :: Union{Function, Nothing} = nothing,
    verbose    :: Bool = false,
    debug      :: Union{Function, Nothing} = nothing,
    downloader :: Union{Downloader, Nothing} = nothing,
) :: ArgWrite
    arg_write(output) do output
        response = request(
            url,
            output = output,
            method = method,
            headers = headers,
            timeout = timeout,
            progress = progress,
            verbose = verbose,
            debug = debug,
            downloader = downloader,
        )::Response
        status_ok(response) && return output
        throw(RequestError(url, Curl.CURLE_OK, "", response))
    end
end

## request API ##

"""
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

        url        :: AbstractString
        input      :: Union{AbstractString, AbstractCmd, IO}
        output     :: Union{AbstractString, AbstractCmd, IO}
        method     :: AbstractString
        headers    :: Union{AbstractVector, AbstractDict}
        timeout    :: Real
        progress   :: (dl_total, dl_now, ul_total, ul_now) --> Any
        verbose    :: Bool
        debug      :: (type, message) --> Any
        throw      :: Bool
        downloader :: Downloader

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
"""
function request(
    url        :: AbstractString;
    input      :: Union{ArgRead, Nothing} = nothing,
    output     :: Union{ArgWrite, Nothing} = nothing,
    method     :: Union{AbstractString, Nothing} = nothing,
    headers    :: Union{AbstractVector, AbstractDict} = Pair{String,String}[],
    timeout    :: Real = Inf,
    progress   :: Union{Function, Nothing} = nothing,
    verbose    :: Bool = false,
    debug      :: Union{Function, Nothing} = nothing,
    throw      :: Bool = true,
    downloader :: Union{Downloader, Nothing} = nothing,
) :: Union{Response, RequestError}
    if downloader === nothing
        lock(DOWNLOAD_LOCK) do
            downloader = DOWNLOADER[]
            if downloader === nothing
                downloader = DOWNLOADER[] = Downloader()
            end
        end
    end
    local response
    have_input = input !== nothing
    have_output = output !== nothing
    input = something(input, devnull)
    output = something(output, devnull)
    input_size = arg_read_size(input)
    if input_size === nothing
        # take input_size from content-length header if one is supplied
        input_size = content_length(headers)
    end
    progress = p_func(progress, input, output)
    arg_read(input) do input
        arg_write(output) do output
            with_handle(Easy()) do easy
                # setup the request
                set_url(easy, url)
                set_timeout(easy, timeout)
                set_verbose(easy, verbose)
                set_debug(easy, debug)
                add_headers(easy, headers)

                # libcurl does not set the default header reliably so set it
                # explicitly unless user has specified it, xref
                # https://github.com/JuliaLang/Pkg.jl/pull/2357
                if !any(kv -> lowercase(kv[1]) == "user-agent", headers)
                    Curl.add_header(easy, "User-Agent", Curl.USER_AGENT)
                end

                if have_input
                    enable_upload(easy)
                    if input_size !== nothing
                        set_upload_size(easy, input_size)
                    end
                    if applicable(seek, input, 0)
                        set_seeker(easy) do offset
                            seek(input, Int(offset))
                        end
                    end
                else
                    set_body(easy, have_output && method != "HEAD")
                end
                method !== nothing && set_method(easy, method)
                progress !== nothing && enable_progress(easy)
                set_ca_roots(downloader, easy)
                info = (url = url, method = method, headers = headers)
                easy_hook(downloader, easy, info)

                # do the request
                add_handle(downloader.multi, easy)
                try # ensure handle is removed
                    @sync begin
                        @async for buf in easy.output
                            write(output, buf)
                        end
                        if progress !== nothing
                            @async for prog in easy.progress
                                progress(prog...)
                            end
                        end
                        if have_input
                            @async upload_data(easy, input)
                        end
                    end
                finally
                    remove_handle(downloader.multi, easy)
                end

                # return the response or throw an error
                response = Response(get_response_info(easy)...)
                easy.code == Curl.CURLE_OK && return response
                message = get_curl_errstr(easy)
                response = RequestError(url, easy.code, message, response)
                throw && Base.throw(response)
            end
        end
    end
    return response
end

## helper functions ##

function p_func(progress::Function, input::ArgRead, output::ArgWrite)
    hasmethod(progress, NTuple{4,Int}) && return progress
    hasmethod(progress, NTuple{2,Int}) ||
        throw(ArgumentError("invalid progress callback"))

    input === devnull && output !== devnull &&
        return (total, now, _, _) -> progress(total, now)
    input !== devnull && output === devnull &&
        return (_, _, total, now) -> progress(total, now)

    (dl_total, dl_now, ul_total, ul_now) ->
        progress(dl_total + ul_total, dl_now + ul_now)
end
p_func(progress::Nothing, input::ArgRead, output::ArgWrite) = nothing

arg_read_size(path::AbstractString) = filesize(path)
arg_read_size(io::Base.GenericIOBuffer) = bytesavailable(io)
arg_read_size(::Base.DevNull) = 0
arg_read_size(::Any) = nothing

function content_length(headers::Union{AbstractVector, AbstractDict})
    for (key, value) in headers
        if lowercase(key) == "content-length" && isa(value, AbstractString)
            return tryparse(Int, value)
        end
    end
    return nothing
end

"""
    default_downloader!(
        downloader = <none>
    ) 

        downloader :: Downloader

Set the default `Downloader`. If no argument is provided, resets the default downloader so that a fresh one is created the next time the default downloader is needed.
"""
function default_downloader!(
    downloader :: Union{Downloader, Nothing} = nothing
)
    lock(DOWNLOAD_LOCK) do
        DOWNLOADER[] = downloader
    end
end

end # module

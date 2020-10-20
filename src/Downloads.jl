module Downloads

using Base.Experimental: @sync
using ArgTools

include("Curl/Curl.jl")
using .Curl

## Base download API ##

export download, request, Downloader, Response

"""
    Downloader(; [ grace::Real = 30 ])

`Downloader` objects are used to perform individual `download` operations.
Connections, lookups and other resources are shared within a `Downloader`. These
connections and resources are cleaned up when the `Downloader` is garbage
collected or a configurable grace period (default: 30 seconds) after the last
time the `Downloader` was used to download anything. If the grace period is set
to zero, all resources will be cleaned up as soon as there are no associated
downloads in progress. If the grace period is set to `Inf` then resources are
not cleaned up until the `Downloader` object is garbage collected.
"""
struct Downloader
    multi::Multi
end
Downloader(; grace::Real=30) = Downloader(Multi(grace_ms(grace)))

function grace_ms(grace::Real)
    grace < 0 && throw(ArgumentError("grace period cannot be negative: $grace"))
    grace <= typemax(UInt64) ÷ 1000 ? round(UInt64, 1000*grace) : typemax(UInt64)
end

"""
    struct Response
        url     :: String
        status  :: Int
        message :: String
        headers :: Vector{Pair{String,String}}
    end

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
"""
struct Response
    url::String
    status::Int
    message::String
    headers::Vector{Pair{String,String}}
end

"""
    download(url, [ output = tempfile() ];
        [ headers = <none>, ]
        [ method = "GET", ]
        [ progress = <none>, ]
        [ verbose = false, ]
        [ downloader = <default>, ]
    ) -> output

        url        :: AbstractString
        output     :: Union{AbstractString, AbstractCmd, IO}
        headers    :: Union{AbstractVector, AbstractDict}
        method     :: AbstractString
        progress   :: (total::Integer, now::Integer) --> Any
        verbose    :: Bool
        downloader :: Downloader

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
"""
function download(
    url        :: AbstractString,
    output     :: Union{ArgWrite, Nothing} = nothing;
    method     :: Union{AbstractString, Nothing} = nothing,
    headers    :: Union{AbstractVector, AbstractDict} = Pair{String,String}[],
    progress   :: Function = (total, now) -> nothing,
    verbose    :: Bool = false,
    downloader :: Union{Downloader, Nothing} = nothing,
) :: ArgWrite
    make_request(
        url = url,
        output = output,
        method = method,
        headers = headers,
        progress = (total, now, _, _) -> progress(total, now),
        downloader = downloader,
        verbose = verbose,
    ) do easy
        status = get_response_status(easy)
        200 ≤ status < 300 && return
        message = get_error_message(easy)
        error("$message while downloading $url")
    end
end

"""
    request(url;
        [ output = devnull, ]
        [ headers = <none>, ]
        [ method = "GET", ]
        [ progress = <none>, ]
        [ verbose = false, ]
        [ downloader = <default>, ]
    ) -> output

        url        :: AbstractString
        output     :: Union{AbstractString, AbstractCmd, IO}
        headers    :: Union{AbstractVector, AbstractDict}
        method     :: AbstractString
        progress   :: (dl_total, dl_now, ul_total, ul_now) --> Any
        verbose    :: Bool
        downloader :: Downloader

Make a request to the given url, returning a [`Response`](@ref) object capturing
the status, headers and other information about the response. The body of the
reponse is written to `output` if specified and discarded otherwise.

Other options are the same as for `download` except for `progress` which must be
a function accepting four integer arguments (rather than two), indicating both
upload and download progress.
"""
function request(
    url        :: AbstractString;
    method     :: Union{AbstractString, Nothing} = nothing,
    output     :: ArgWrite = devnull,
    headers    :: Union{AbstractVector, AbstractDict} = Pair{String,String}[],
    progress   :: Function = (dl_total, dl_now, ul_total, ul_now) -> nothing,
    verbose    :: Bool = false,
    downloader :: Union{Downloader, Nothing} = nothing,
) :: Response
    make_request(
        url = url,
        method = method,
        output = output,
        headers = headers,
        progress = progress,
        downloader = downloader,
        verbose = verbose,
    ) do easy
        easy.code == Curl.CURLE_OK &&
            return Response(get_response_info(easy)...)
        message = get_error_message(easy)
        error("$message while requesting $url")
    end
end

## shared internal request functionality ##

const DOWNLOAD_LOCK = ReentrantLock()
const DOWNLOADER = Ref{Union{Downloader, Nothing}}(nothing)

function make_request(
    body       :: Function;
    url        :: AbstractString,
    method     :: Union{AbstractString, Nothing} = nothing,
    output     :: Union{ArgWrite, Nothing} = devnull,
    headers    :: Union{AbstractVector, AbstractDict} = Pair{String,String}[],
    progress   :: Function = (dl_total, dl_now, ul_total, ul_now) -> nothing,
    verbose    :: Bool = false,
    downloader :: Union{Downloader, Nothing} = nothing,
)
    lock(DOWNLOAD_LOCK) do
        yield() # let other downloads finish
        downloader isa Downloader && return
        while true
            downloader = DOWNLOADER[]
            downloader isa Downloader && return
            DOWNLOADER[] = Downloader()
        end
    end
    this = nothing
    that = arg_write(output) do io
        with_handle(Easy()) do easy
            set_url(easy, url)
            method !== nothing && set_method(easy, method)
            set_verbose(easy, verbose)
            enable_progress(easy, true)
            for hdr in headers
                hdr isa Pair{<:AbstractString, <:Union{AbstractString, Nothing}} ||
                    throw(ArgumentError("invalid header: $(repr(hdr))"))
                add_header(easy, hdr)
            end
            add_handle(downloader.multi, easy)
            try # ensure handle is removed
                @sync begin
                    @async for buf in easy.output
                        write(io, buf)
                    end
                    @async for prog in easy.progress
                        progress(prog...)
                    end
                end
            finally
                remove_handle(downloader.multi, easy)
            end
            this = body(easy)
        end
    end
    something(this, that)
end

end # module

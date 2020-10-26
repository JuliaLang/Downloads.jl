module Downloads

using Base.Experimental: @sync
using ArgTools

include("Curl/Curl.jl")
using .Curl

export download, request, Downloader, Response, RequestError

## Downloader: shared pool of connections ##

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

const DOWNLOAD_LOCK = ReentrantLock()
const DOWNLOADER = Ref{Union{Downloader, Nothing}}(nothing)

## download API ##

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
    arg_write(output) do output
        response = request(
            url,
            output = output,
            method = method,
            headers = headers,
            progress = (total, now, _, _) -> progress(total, now),
            downloader = downloader,
            verbose = verbose,
        )
        response isa Response && 200 ≤ response.status < 300 && return output
        throw(RequestError(url, Curl.CURLE_OK, "", response))
    end
end

## request API ##

"""
    struct Response
        url     :: String
        status  :: Int
        message :: String
        headers :: Vector{Pair{String,String}}
    end

`Response` is a type capturing the properties of a successful response to a
request as an object. It has the following fields:

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
    url     :: String # redirected URL
    status  :: Int
    message :: String
    headers :: Vector{Pair{String,String}}
end

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
successful but there was a protocol-level error indicated by a status code
that is not in the 2xx range, in which case `code` will be zero and the
`message` field will be the empty string. The `request` API only throws a
`RequestError` if the libcurl error `code` is non-zero, in which case the
included `response` object is likely to have a `status` of zero and an
empty message. There are, however, situations where a curl-level error is
thrown due to a protocol error, in which case both the inner and outer
code and message may be of interest.
"""
struct RequestError <: Exception
    url      :: String # original URL
    code     :: Int
    message  :: String
    response :: Response
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

function Base.showerror(io::IO, err::RequestError)
    print(io, "$(error_message(err)) while downloading $(err.url)")
end

"""
    request(url;
        [ output = devnull, ]
        [ headers = <none>, ]
        [ method = "GET", ]
        [ progress = <none>, ]
        [ verbose = false, ]
        [ downloader = <default>, ]
    ) -> Union{Response, RequestError}

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
    throw      :: Bool = true,
    downloader :: Union{Downloader, Nothing} = nothing,
) :: Union{Response, RequestError}
    lock(DOWNLOAD_LOCK) do
        yield() # let other downloads finish
        downloader isa Downloader && return
        while true
            downloader = DOWNLOADER[]
            downloader isa Downloader && return
            DOWNLOADER[] = Downloader()
        end
    end
    local response
    arg_write(output) do output
        with_handle(Easy()) do easy
            # setup the request
            set_url(easy, url)
            method !== nothing && set_method(easy, method)
            set_verbose(easy, verbose)
            enable_progress(easy, true)
            for hdr in headers
                hdr isa Pair{<:AbstractString, <:Union{AbstractString, Nothing}} ||
                    throw(ArgumentError("invalid header: $(repr(hdr))"))
                add_header(easy, hdr)
            end

            # do the request
            add_handle(downloader.multi, easy)
            try # ensure handle is removed
                @sync begin
                    @async for buf in easy.output
                        write(output, buf)
                    end
                    @async for prog in easy.progress
                        progress(prog...)
                    end
                end
            finally
                remove_handle(downloader.multi, easy)
            end

            # return the response or throw an error
            response = Response(get_response_info(easy)...)
            easy.code == Curl.CURLE_OK && return response
            response = RequestError(url, easy.code, get_curl_errstr(easy), response)
            throw && Base.throw(response)
        end
    end
    return response
end

end # module

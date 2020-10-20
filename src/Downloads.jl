module Downloads

using Base.Experimental: @sync
using ArgTools

include("Curl/Curl.jl")
using .Curl

## Base download API ##

export download

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

"""
    download(url, [ output = tempfile() ];
        [ downloader = <default downloader>, ]
        [ headers = <none>, ]
        [ progress = <none>, ]
        [ verbose = false, ]
    ) -> output

        url        :: AbstractString
        output     :: Union{AbstractString, AbstractCmd, IO}
        headers    :: Union{AbstractVector, AbstractDict}
        progress   :: (total::Integer, now::Integer) --> Any
        downloader :: Downloader
        verbose    :: Bool

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
"""
function download(
    url::AbstractString,
    output::Union{ArgWrite, Nothing} = nothing;
    headers::Union{AbstractVector, AbstractDict} = Pair{String,String}[],
    progress::Function = (total, now) -> nothing,
    downloader::Union{Downloader, Nothing} = nothing,
    verbose::Bool = false,
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
    arg_write(output) do io
        with_handle(Easy()) do easy
            set_url(easy, url)
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
                    @async for buf in easy.buffers
                        write(io, buf)
                    end
                    @async for prog in easy.progress
                        progress(prog.dl_total, prog.dl_now)
                    end
                    for buf in easy.buffers
                        write(io, buf)
                    end
                end
            finally
                remove_handle(downloader.multi, easy)
            end
            status = get_response_code(easy)
            200 ≤ status < 300 && return
            message = get_error_message(easy)
            error("$message while downloading $url")
        end
    end
end

## experimental request API ##

export request, Request, Response

struct Request
    io::IO
    url::String
    headers::Vector{Pair{String,String}}
end

struct Response
    url::String
    status::Int
    response::String
    headers::Vector{Pair{String,String}}
end

function request(req::Request, multi = Multi(); progress = p -> nothing)
    with_handle(Easy()) do easy
        set_url(easy, req.url)
        for hdr in req.headers
            add_header(easy, hdr)
        end
        enable_progress(easy, true)
        add_handle(multi, easy)
        @sync begin
            @async for buf in easy.buffers
                write(req.io, buf)
            end
            @async for prog in easy.progress
                progress(prog)
            end
        end
        remove_handle(multi, easy)
        url = get_effective_url(easy)
        status = get_response_code(easy)
        response, headers = get_response_headers(easy)
        return Response(url, status, response, headers)
    end
end

end # module

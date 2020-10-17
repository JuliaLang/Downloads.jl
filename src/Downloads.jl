module Downloads

using Base.Experimental: @sync
using ArgTools

include("Curl/Curl.jl")
using .Curl

## Base download API ##

export download

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
    download(url, [ output = tempfile() ]; [ headers ]) -> output

        url     :: AbstractString
        output  :: Union{AbstractString, AbstractCmd, IO}
        headers :: Union{AbstractVector, AbstractDict}

Download a file from the given url, saving it to `output` or if not specified,
a temporary path. The `output` can also be an `IO` handle, in which case the
body of the response is streamed to that handle and the handle is returned. If
`output` is a command, the command is run and output is sent to it on stdin.

If the `headers` keyword argument is provided, it must be a vector or dictionary
whose elements are all pairs of strings. These pairs are passed as headers when
downloading URLs with protocols that supports them, such as HTTP/S.
"""
function download(
    url::AbstractString,
    output::Union{ArgWrite, Nothing} = nothing;
    headers::Union{AbstractVector, AbstractDict} = Pair{String,String}[],
    downloader::Union{Downloader, Nothing} = nothing,
    progress::Function = p -> nothing,
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
                        progress(prog)
                    end
                    for buf in easy.buffers
                        write(io, buf)
                    end
                end
            finally
                remove_handle(downloader.multi, easy)
            end
            status = get_response_code(easy)
            status == 200 && return
            message = if easy.code == Curl.CURLE_OK
                get_response_headers(easy)[1]
            elseif easy.errbuf[1] == 0
                unsafe_string(Curl.curl_easy_strerror(easy.code))
            else
                GC.@preserve easy unsafe_string(pointer(easy.errbuf))
            end
            message = chomp(message)
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

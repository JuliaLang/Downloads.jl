module Downloads

include("Curl/Curl.jl")
using .Curl

## Base download API ##

export download

struct Downloader
    multi::Multi
    Downloader() = new(Multi())
end

const DEFAULT_DOWNLOADER = Ref{Union{Downloader, Nothing}}(nothing)

function default_downloader()::Downloader
    DEFAULT_DOWNLOADER[] isa Downloader && return DEFAULT_DOWNLOADER[]
    DEFAULT_DOWNLOADER[] = Downloader()
end

const Headers = Union{AbstractVector, AbstractDict}

"""
    download(url, [ path = tempfile() ]; [ headers ]) -> path
    download(url, io; [ headers ]) -> io

        url     :: AbstractString
        path    :: AbstractString
        io      :: IO
        headers :: Union{AbstractVector, AbstractDict}

Download a file from the given url, saving it to the location `path`, or if not
specified, a temporary path. Returns the path of the downloaded file. If the
second argument is an IO handle instead of a path, the body of the downloaded
URL is written to the handle instead and the handle is returned.

If the `headers` keyword argument is provided, it must be a vector or dictionary
whose elements are all pairs of strings. These pairs are passed as headers when
downloading URLs with protocols that supports them, such as HTTP/S.
"""
function download(
    url::AbstractString,
    io::IO;
    headers::Headers = Pair{String,String}[],
    downloader::Downloader = default_downloader(),
)
    easy = Easy()
    set_url(easy, url)
    for hdr in headers
        hdr isa Pair{<:AbstractString, <:Union{AbstractString, Nothing}} ||
            throw(ArgumentError("invalid header: $(repr(hdr))"))
        add_header(easy, hdr)
    end
    add_handle(downloader.multi, easy)
    for buf in easy.buffers
        write(io, buf)
    end
    remove_handle(downloader.multi, easy)
    status = get_response_code(easy)
    status == 200 && return io
    if easy.code == Curl.CURLE_OK
        message = get_response_headers(easy)[1]
    else
        message = GC.@preserve easy unsafe_string(pointer(easy.errbuf))
    end
    error(message)
end

function download(
    url::AbstractString,
    path::AbstractString = tempname(),
    headers::Headers = Pair{String,String}[],
    downloader::Downloader = default_downloader(),
)
    try open(path, write=true) do io
            download(url, io, headers = headers, downloader = downloader)
        end
    catch
        rm(path, force=true)
        rethrow()
    end
    return path
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

function request(req::Request, multi = Multi(), progress = p -> nothing)
    easy = Easy()
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

end # module

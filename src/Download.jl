module Download

export Request, Response, download

include("Curl/Curl.jl")
using .Curl

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

function Response(easy::Easy)
    url = get_effective_url(easy)
    status = get_response_code(easy)
    response, headers = get_response_headers(easy)
    return Response(url, status, response, headers)
end

function get(req::Request, multi = Multi(), progress = p -> nothing)
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
    return Response(easy)
end

function download(
    multi::Multi,
    url::AbstractString,
    io::IO = stdout,
    headers = Union{}[],
)
    easy = Easy()
    set_url(easy, url)
    for hdr in headers
        add_header(easy, hdr)
    end
    add_handle(multi, easy)
    for buf in easy.buffers
        write(io, buf)
    end
    remove_handle(multi, easy)
    return io
end

function download(
    url::AbstractString,
    io::IO = stdout,
    headers = Union{}[],
)
    download(Multi(), url, io, headers)
end

end # module

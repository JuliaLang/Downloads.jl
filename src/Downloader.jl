module Downloader

export Curl, download, add_download

using LibCURL

mutable struct Curl
    multi::Ptr{Cvoid}
    timer::Ptr{Cvoid}
    roots::Vector{IO}
end

include("helpers.jl")
include("callbacks.jl")

@check curl_global_init(CURL_GLOBAL_ALL)

const CERTS_FILE = normpath(Sys.BINDIR, "..", "share", "julia", "cert.pem")

function Curl()
    # libcurl setup
    multi = curl_multi_init()
    @check curl_multi_setopt(multi, CURLMOPT_TIMERFUNCTION, timer_cb)
    @check curl_multi_setopt(multi, CURLMOPT_SOCKETFUNCTION, socket_cb)

    # libuv setup
    timer = ccall(:jl_malloc, Ptr{Cvoid}, (Csize_t,), Base._sizeof_uv_timer)
    uv_timer_init(timer)

    # create curl object & store in timer
    curl = Curl(multi, timer, IO[])
    curl_p = pointer_from_objref(curl)
    unsafe_store!(convert(Ptr{Ptr{Cvoid}}, timer), curl_p)

    # add finalizer & return
    finalizer(curl) do curl
        uv_close(curl.timer, cglobal(:jl_free))
        curl_multi_cleanup(curl.multi)
    end
end

function add_download(curl::Curl, url::AbstractString, io::IO)
    # init a single curl handle
    easy = curl_easy_init()

    # HTTP options
    @check curl_easy_setopt(curl.multi, CURLOPT_POSTREDIR, CURL_REDIR_POST_ALL)

    # HTTPS: tell curl where to find certs
    @check curl_easy_setopt(easy, CURLOPT_CAINFO, CERTS_FILE)

    # set the URL and request to follow redirects
    @check curl_easy_setopt(easy, CURLOPT_URL, url)
    @check curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, true)

    # associate IO object with easy handle
    io_p = pointer_from_objref(io)
    io in curl.roots || push!(curl.roots, io)
    @check curl_easy_setopt(easy, CURLOPT_WRITEDATA, io_p)

    # set the generic write callback
    @check curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, write_cb)

    # add curl handle to be multiplexed
    @check curl_multi_add_handle(curl.multi, easy)

    return handle
end

function download(curl::Curl, url::AbstractString)
    io = IOBuffer()
    add_download(curl, url, io)
    sleep(1)
    return String(take!(io))
end

end # module

module Downloader

export add_download, download

using LibCURL

mutable struct Curl
    multi::Ptr{Cvoid}
    timer::Ptr{Cvoid}
    roots::Vector{IO}
end

include("helpers.jl")
include("callbacks.jl")

## setup & teardown ##

function Curl()
    uv_timer_size = Base._sizeof_uv_timer
    timer = ccall(:jl_malloc, Ptr{Cvoid}, (Csize_t,), uv_timer_size)
    uv_timer_init(timer)

    @check curl_global_init(CURL_GLOBAL_ALL)
    multi = curl_multi_init()

    # set timer callback
    timer_cb = @cfunction(timer_callback, Cint, (Ptr{Cvoid}, Clong, Ptr{Cvoid}))
    @check curl_multi_setopt(multi, CURLMOPT_TIMERFUNCTION, timer_cb)

    # set socket callback
    socket_cb = @cfunction(socket_callback,
        Cint, (Ptr{Cvoid}, curl_socket_t, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
    @check curl_multi_setopt(multi, CURLMOPT_SOCKETFUNCTION, socket_cb)

    finalizer(Curl(multi, timer, IO[])) do curl
        uv_close(curl.timer, cglobal(:jl_free))
        curl_multi_cleanup(curl.multi)
    end
end

function __init__()
    global curl = Curl()
end

## API ##

function add_download(url::AbstractString, io::IO)
    # init a single curl handle
    handle = curl_easy_init()

    # HTTP options
    @check curl_easy_setopt(handle, CURLOPT_POSTREDIR, CURL_REDIR_POST_ALL)

    # HTTPS: tell curl where to find certs
    certs_file = normpath(Sys.BINDIR, "..", "share", "julia", "cert.pem")
    @check curl_easy_setopt(handle, CURLOPT_CAINFO, certs_file)

    # set the URL and request to follow redirects
    @check curl_easy_setopt(handle, CURLOPT_URL, url)
    @check curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, true)

    # associate IO object with handle
    push!(curl.roots, io) # TOOD: remove on completion
    p = pointer_from_objref(io)
    @check curl_easy_setopt(handle, CURLOPT_WRITEDATA, p)

    # set write callback
    write_cb = @cfunction(write_callback,
        Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
    @check curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, write_cb)

    # add curl handle to be multiplexed
    @check curl_multi_add_handle(curl.multi, handle)

    return handle
end

function download(url::AbstractString)
    io = IOBuffer()
    add_download(url, io)
    sleep(1)
    return String(take!(io))
end

end # module

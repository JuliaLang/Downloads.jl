module Downloader

export add_download, download

using LibCURL

const CERTS_FILE = normpath(Sys.BINDIR, "..", "share", "julia", "cert.pem")

include("helpers.jl")
include("callbacks.jl")

## libuv setup ##

const timer = ccall(:jl_malloc, Ptr{Cvoid}, (Csize_t,), Base._sizeof_uv_timer)

uv_timer_init(timer)

## curl setup ##

@check curl_global_init(CURL_GLOBAL_ALL)

const curl = curl_multi_init()

# set various callbacks
@check curl_multi_setopt(curl, CURLMOPT_TIMERFUNCTION, timer_cb)
@check curl_multi_setopt(curl, CURLMOPT_SOCKETFUNCTION, socket_cb)

## cleanup ##

atexit() do
    uv_close(timer, cglobal(:jl_free))
    curl_multi_cleanup(curl)
end

## API ##

function add_download(url::AbstractString, io::IO)
    # init a single curl handle
    handle = curl_easy_init()

    # HTTP options
    @check curl_easy_setopt(curl, CURLOPT_POSTREDIR, CURL_REDIR_POST_ALL)

    # HTTPS: tell curl where to find certs
    @check curl_easy_setopt(handle, CURLOPT_CAINFO, CERTS_FILE)

    # set the URL and request to follow redirects
    @check curl_easy_setopt(handle, CURLOPT_URL, url)
    @check curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, true)

    # associate IO object with handle
    # TODO: may need to root `io` to keep it alive
    p = pointer_from_objref(io)
    @check curl_easy_setopt(handle, CURLOPT_WRITEDATA, p)
    @check curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, write_cb)

    # add curl handle to be multiplexed
    @check curl_multi_add_handle(curl, handle)

    return handle
end

function download(url::AbstractString)
    io = IOBuffer()
    add_download(url, io)
    sleep(1)
    return String(take!(io))
end

end # module

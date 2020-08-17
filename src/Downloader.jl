module Downloader

export add_download, download

using LibCURL

mutable struct Curl
    multi::Ptr{Cvoid}
    timer::Ptr{Cvoid}
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

    # create object & set finalizer
    curl = Curl(multi, timer)
    finalizer(curl) do curl
        uv_close(curl.timer, cglobal(:jl_free))
        curl_multi_cleanup(curl.multi)
    end
    curl_p = pointer_from_objref(curl)

    # stash curl pointer in timer
    ## TODO: use a member access API
    unsafe_store!(convert(Ptr{Ptr{Cvoid}}, timer), curl_p)

    # set timer callback
    timer_cb = @cfunction(timer_callback, Cint, (Ptr{Cvoid}, Clong, Ptr{Cvoid}))
    @check curl_multi_setopt(multi, CURLMOPT_TIMERFUNCTION, timer_cb)
    @check curl_multi_setopt(multi, CURLMOPT_TIMERDATA, curl_p)

    # set socket callback
    socket_cb = @cfunction(socket_callback,
        Cint, (Ptr{Cvoid}, curl_socket_t, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
    @check curl_multi_setopt(multi, CURLMOPT_SOCKETFUNCTION, socket_cb)
    @check curl_multi_setopt(multi, CURLMOPT_SOCKETDATA, curl_p)

    return curl
end

function add_download(curl::Curl, url::AbstractString, ch::Channel)
    # init a single curl handle
    easy = curl_easy_init()

    # curl options
    @check curl_easy_setopt(easy, CURLOPT_NOSIGNAL, true)
    @check curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, true)
    @check curl_easy_setopt(easy, CURLOPT_POSTREDIR, CURL_REDIR_POST_ALL)

    # tell curl where to find HTTPS certs
    certs_file = normpath(Sys.BINDIR, "..", "share", "julia", "cert.pem")
    @check curl_easy_setopt(easy, CURLOPT_CAINFO, certs_file)

    # set write callback
    write_cb = @cfunction(write_callback,
        Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
    @check curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, write_cb)

    # set the URL
    @check curl_easy_setopt(easy, CURLOPT_URL, url)

    # associate channel with handle
    ch_p = pointer_from_objref(ch)
    @check curl_easy_setopt(easy, CURLOPT_PRIVATE, ch_p)
    @check curl_easy_setopt(easy, CURLOPT_WRITEDATA, ch_p)

    # add curl handle to be multiplexed
    @check curl_multi_add_handle(curl.multi, easy)

    return easy
end

## API ##

function download(curl::Curl, url::AbstractString, io::IO)
    ch = Channel{Vector{UInt8}}(Inf)
    add_download(curl, url, ch)
    for buf in ch
        write(io, buf)
    end
    return io
end

end # module

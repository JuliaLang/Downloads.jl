module Downloader

export add_download, download

using LibCURL

const CURL_VERSION = unsafe_string(curl_version())
const USER_AGENT = "$CURL_VERSION julia/$VERSION"

include("helpers.jl")

mutable struct CurlEasy
    handle::Ptr{Cvoid}
    headers::Ptr{curl_slist_t}
    channel::Channel{Vector{UInt8}}
end

mutable struct CurlMulti
    handle::Ptr{Cvoid}
    timer::Ptr{Cvoid}
end

include("callbacks.jl")

## setup & teardown ##

function CurlMulti()
    uv_timer_size = Base._sizeof_uv_timer
    timer = ccall(:jl_malloc, Ptr{Cvoid}, (Csize_t,), uv_timer_size)
    uv_timer_init(timer)

    @check curl_global_init(CURL_GLOBAL_ALL)
    handle = curl_multi_init()

    # create object & set finalizer
    multi = CurlMulti(handle, timer)
    finalizer(multi) do multi
        uv_close(multi.timer, cglobal(:jl_free))
        curl_multi_cleanup(multi.handle)
    end
    multi_p = pointer_from_objref(multi)

    # stash curl pointer in timer
    ## TODO: use a member access API
    unsafe_store!(convert(Ptr{Ptr{Cvoid}}, timer), multi_p)

    # set timer callback
    timer_cb = @cfunction(timer_callback, Cint, (Ptr{Cvoid}, Clong, Ptr{Cvoid}))
    @check curl_multi_setopt(handle, CURLMOPT_TIMERFUNCTION, timer_cb)
    @check curl_multi_setopt(handle, CURLMOPT_TIMERDATA, multi_p)

    # set socket callback
    socket_cb = @cfunction(socket_callback,
        Cint, (Ptr{Cvoid}, curl_socket_t, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
    @check curl_multi_setopt(handle, CURLMOPT_SOCKETFUNCTION, socket_cb)
    @check curl_multi_setopt(handle, CURLMOPT_SOCKETDATA, multi_p)

    return multi
end

function CurlEasy(url::AbstractString, headers = Union{}[])
    # init a single curl handle
    handle = curl_easy_init()

    # curl options
    curl_easy_setopt(handle, CURLOPT_TCP_FASTOPEN, true) # failure ok, unsupported
    @check curl_easy_setopt(handle, CURLOPT_NOSIGNAL, true)
    @check curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, true)
    @check curl_easy_setopt(handle, CURLOPT_MAXREDIRS, 10)
    @check curl_easy_setopt(handle, CURLOPT_POSTREDIR, CURL_REDIR_POST_ALL)
    @check curl_easy_setopt(handle, CURLOPT_USERAGENT, USER_AGENT)

    # tell curl where to find HTTPS certs
    certs_file = normpath(Sys.BINDIR, "..", "share", "julia", "cert.pem")
    @check curl_easy_setopt(handle, CURLOPT_CAINFO, certs_file)

    # set write callback
    write_cb = @cfunction(write_callback,
        Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
    @check curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, write_cb)

    # set headers for the handle
    headers_p = to_curl_slist(headers)
    @check curl_easy_setopt(handle, CURLOPT_HTTPHEADER, headers_p)

    # set the URL to download
    @check curl_easy_setopt(handle, CURLOPT_URL, url)

    # create object & set finalizer
    channel = Channel{Vector{UInt8}}(Inf)
    easy = CurlEasy(handle, headers_p, channel)
    finalizer(easy) do easy
        curl_easy_cleanup(easy.handle)
        curl_slist_free_all(easy.headers)
    end
    easy_p = pointer_from_objref(easy)

    # associate the easy object with the curl handle
    @check curl_easy_setopt(handle, CURLOPT_PRIVATE, easy_p)

    # set the channel as the write callback user data
    channel_p = pointer_from_objref(channel)
    @check curl_easy_setopt(handle, CURLOPT_WRITEDATA, channel_p)

    return easy
end

## API ##

function download(
    multi::CurlMulti,
    url::AbstractString,
    io::IO;
    headers = Union{}[],
)
    easy = CurlEasy(url, headers)
    @check curl_multi_add_handle(multi.handle, easy.handle)
    for buf in easy.channel
        write(io, buf)
    end
    @check curl_multi_remove_handle(multi.handle, easy.handle)
    return io
end

end # module

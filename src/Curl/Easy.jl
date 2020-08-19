mutable struct Easy
    handle  :: Ptr{Cvoid}
    channel :: Channel{Vector{UInt8}}
    headers :: Ptr{curl_slist_t}
end

function Easy()
    easy = Easy(curl_easy_init(), Channel{Vector{UInt8}}(Inf), C_NULL)
    finalizer(easy) do easy
        curl_easy_cleanup(easy.handle)
        curl_slist_free_all(easy.headers)
    end
    easy_p = pointer_from_objref(easy)
    @check curl_easy_setopt(easy.handle, CURLOPT_PRIVATE, easy_p)
    add_callbacks(easy)
    set_defaults(easy)
    return easy
end

# request options

function set_defaults(easy::Easy)
    # curl options
    curl_easy_setopt(easy.handle, CURLOPT_TCP_FASTOPEN, true) # failure ok, unsupported
    @check curl_easy_setopt(easy.handle, CURLOPT_NOSIGNAL, true)
    @check curl_easy_setopt(easy.handle, CURLOPT_FOLLOWLOCATION, true)
    @check curl_easy_setopt(easy.handle, CURLOPT_AUTOREFERER, true)
    @check curl_easy_setopt(easy.handle, CURLOPT_MAXREDIRS, 10)
    @check curl_easy_setopt(easy.handle, CURLOPT_POSTREDIR, CURL_REDIR_POST_ALL)
    @check curl_easy_setopt(easy.handle, CURLOPT_USERAGENT, USER_AGENT)

    # tell curl where to find HTTPS certs
    certs_file = normpath(Sys.BINDIR, "..", "share", "julia", "cert.pem")
    @check curl_easy_setopt(easy.handle, CURLOPT_CAINFO, certs_file)
end

function set_url(easy::Easy, url::AbstractString)
    @check curl_easy_setopt(easy.handle, CURLOPT_URL, url)
end

function add_header(easy::Easy, hdr::Union{String, SubString{String}})
    easy.headers = curl_slist_append(easy.headers, hdr)
    @check curl_easy_setopt(easy.handle, CURLOPT_HTTPHEADER, easy.headers)
end

add_header(easy::Easy, hdr::AbstractString) = add_header(easy, string(hdr)::String)
add_header(easy::Easy, key::AbstractString, val::AbstractString) =
    add_header(easy, isempty(val) ? "$key;" : "$key: $val")
add_header(easy::Easy, key::AbstractString, val::Nothing) =
    add_header(easy, "$key:")
add_header(easy::Easy, pair::Pair) = add_header(easy, pair...)

# callbacks

function write_callback(
    data  :: Ptr{Cchar},
    size  :: Csize_t,
    count :: Csize_t,
    ch_p  :: Ptr{Cvoid},
)::Csize_t
    n = size * count
    buf = Array{UInt8}(undef, n)
    ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), buf, data, n)
    ch = unsafe_pointer_to_objref(ch_p)::Channel{Vector{UInt8}}
    put!(ch, buf)
    return n
end

function add_callbacks(easy::Easy)
    # set write callback
    write_cb = @cfunction(write_callback,
        Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
    @check curl_easy_setopt(easy.handle, CURLOPT_WRITEFUNCTION, write_cb)

    # set the channel as the write callback user data
    channel_p = pointer_from_objref(easy.channel)
    @check curl_easy_setopt(easy.handle, CURLOPT_WRITEDATA, channel_p)
end

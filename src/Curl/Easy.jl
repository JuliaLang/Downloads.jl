struct Progress
    dl_total :: curl_off_t
    dl_now   :: curl_off_t
    ul_total :: curl_off_t
    ul_now   :: curl_off_t
end

mutable struct Easy
    handle   :: Ptr{Cvoid}
    progress :: Channel{Progress}
    buffers  :: Channel{Vector{UInt8}}
    req_hdrs :: Ptr{curl_slist_t}
    res_hdrs :: Vector{String}
end

function Easy()
    easy = Easy(
        curl_easy_init(),
        Channel{Progress}(Inf),
        Channel{Vector{UInt8}}(Inf),
        C_NULL,
        String[],
    )
    finalizer(easy) do easy
        curl_easy_cleanup(easy.handle)
        curl_slist_free_all(easy.req_hdrs)
    end
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
    easy.req_hdrs = curl_slist_append(easy.req_hdrs, hdr)
    @check curl_easy_setopt(easy.handle, CURLOPT_HTTPHEADER, easy.req_hdrs)
end

add_header(easy::Easy, hdr::AbstractString) = add_header(easy, string(hdr)::String)
add_header(easy::Easy, key::AbstractString, val::AbstractString) =
    add_header(easy, isempty(val) ? "$key;" : "$key: $val")
add_header(easy::Easy, key::AbstractString, val::Nothing) =
    add_header(easy, "$key:")
add_header(easy::Easy, pair::Pair) = add_header(easy, pair...)

function enable_progress(easy::Easy, on::Bool)
    @check curl_easy_setopt(easy.handle, CURLOPT_NOPROGRESS, !on)
end

# response info

function get_effective_url(easy::Easy)
    url_ref = Ref{Ptr{Cchar}}()
    @check curl_easy_getinfo(easy.handle, CURLINFO_EFFECTIVE_URL, url_ref)
    return unsafe_string(url_ref[])
end

function get_response_code(easy::Easy)
    code_ref = Ref{Clong}()
    @check curl_easy_getinfo(easy.handle, CURLINFO_RESPONSE_CODE, code_ref)
    return Int(code_ref[])
end

function get_response_headers(easy::Easy)
    headers = Pair{String,String}[]
    response = isempty(easy.res_hdrs) ? "" : easy.res_hdrs[1]
    for hdr in easy.res_hdrs
        if occursin(r"^\s*$", hdr)
            # ignore
        elseif (m = match(r"^(HTTP/\d+(?:.\d+)?\s+\d+\b.*?)\s*$", hdr)) !== nothing
            response = m.captures[1]
            empty!(headers)
        elseif (m = match(r"^(\S[^:]*?)\s*:\s*(.*?)\s*$", hdr)) !== nothing
            push!(headers, lowercase(m.captures[1]) => m.captures[2])
        else
            url = get_effective_url(easy)
            status = get_response_code(easy)
            @warn "malformed HTTP header" url status header=hdr
        end
    end
    return response, headers
end

# callbacks

function header_callback(
    data   :: Ptr{Cchar},
    size   :: Csize_t,
    count  :: Csize_t,
    easy_p :: Ptr{Cvoid},
)::Csize_t
    easy = unsafe_pointer_to_objref(easy_p)::Easy
    n = size * count
    hdr = unsafe_string(data, n)
    push!(easy.res_hdrs, hdr)
    return n
end

function write_callback(
    data   :: Ptr{Cchar},
    size   :: Csize_t,
    count  :: Csize_t,
    easy_p :: Ptr{Cvoid},
)::Csize_t
    easy = unsafe_pointer_to_objref(easy_p)::Easy
    n = size * count
    buf = Array{UInt8}(undef, n)
    ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), buf, data, n)
    put!(easy.buffers, buf)
    return n
end

function progress_callback(
    easy_p   :: Ptr{Cvoid},
    dl_total :: curl_off_t,
    dl_now   :: curl_off_t,
    ul_total :: curl_off_t,
    ul_now   :: curl_off_t,
)::Cint
    easy = unsafe_pointer_to_objref(easy_p)::Easy
    put!(easy.progress, Progress(dl_total, dl_now, ul_total, ul_now))
    return 0
end

function add_callbacks(easy::Easy)
    # pointer to easy object
    easy_p = pointer_from_objref(easy)
    @check curl_easy_setopt(easy.handle, CURLOPT_PRIVATE, easy_p)

    # set header callback
    header_cb = @cfunction(header_callback,
        Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
    @check curl_easy_setopt(easy.handle, CURLOPT_HEADERFUNCTION, header_cb)
    @check curl_easy_setopt(easy.handle, CURLOPT_HEADERDATA, easy_p)

    # set write callback
    write_cb = @cfunction(write_callback,
        Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
    @check curl_easy_setopt(easy.handle, CURLOPT_WRITEFUNCTION, write_cb)
    @check curl_easy_setopt(easy.handle, CURLOPT_WRITEDATA, easy_p)

    # set progress callbacks
    progress_cb = @cfunction(progress_callback,
        Cint, (Ptr{Cvoid}, curl_off_t, curl_off_t, curl_off_t, curl_off_t))
    @check curl_easy_setopt(easy.handle, CURLOPT_XFERINFOFUNCTION, progress_cb)
    @check curl_easy_setopt(easy.handle, CURLOPT_XFERINFODATA, easy_p)
end

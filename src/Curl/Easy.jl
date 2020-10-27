mutable struct Easy
    handle   :: Ptr{Cvoid}
    input    :: Union{Vector{UInt8},Nothing}
    ready    :: Threads.Event
    output   :: Channel{Vector{UInt8}}
    progress :: Channel{NTuple{4,Int}}
    req_hdrs :: Ptr{curl_slist_t}
    res_hdrs :: Vector{String}
    code     :: CURLcode
    errbuf   :: Vector{UInt8}
end

const EMPTY_BYTE_VECTOR = UInt8[]

function Easy()
    easy = Easy(
        curl_easy_init(),
        EMPTY_BYTE_VECTOR,
        Threads.Event(),
        Channel{Vector{UInt8}}(Inf),
        Channel{NTuple{4,Int}}(Inf),
        C_NULL,
        String[],
        typemax(CURLcode),
        zeros(UInt8, CURL_ERROR_SIZE),
    )
    finalizer(done!, easy)
    add_callbacks(easy)
    set_defaults(easy)
    return easy
end

function done!(easy::Easy)
    easy.handle == C_NULL && return
    curl_easy_cleanup(easy.handle)
    curl_slist_free_all(easy.req_hdrs)
    easy.handle = C_NULL
    return
end

# request options

function set_defaults(easy::Easy)
    # curl options
    curl_easy_setopt(easy.handle, CURLOPT_TCP_FASTOPEN, true) # failure ok, unsupported
    @check curl_easy_setopt(easy.handle, CURLOPT_NOSIGNAL, true)
    @check curl_easy_setopt(easy.handle, CURLOPT_FOLLOWLOCATION, true)
    @check curl_easy_setopt(easy.handle, CURLOPT_MAXREDIRS, 50)
    @check curl_easy_setopt(easy.handle, CURLOPT_POSTREDIR, CURL_REDIR_POST_ALL)
    @check curl_easy_setopt(easy.handle, CURLOPT_USERAGENT, USER_AGENT)

    # tell curl where to find HTTPS certs
    certs_file = normpath(Sys.BINDIR::String, "..", "share", "julia", "cert.pem")
    @check curl_easy_setopt(easy.handle, CURLOPT_CAINFO, certs_file)
end

function set_url(easy::Easy, url::Union{String, SubString{String}})
    # TODO: ideally, Clang would generate Cstring signatures
    Base.unsafe_convert(Cstring, url) # error checking
    @check curl_easy_setopt(easy.handle, CURLOPT_URL, url)
end
set_url(easy::Easy, url::AbstractString) = set_url(easy, String(url))

function set_method(easy::Easy, method::Union{String, SubString{String}})
    # TODO: ideally, Clang would generate Cstring signatures
    Base.unsafe_convert(Cstring, method) # error checking
    @check curl_easy_setopt(easy.handle, CURLOPT_CUSTOMREQUEST, method)
end
set_method(easy::Easy, method::AbstractString) = set_method(easy, String(method))

function set_verbose(easy::Easy, verbose::Bool)
    @check curl_easy_setopt(easy.handle, CURLOPT_VERBOSE, verbose)
end

function add_header(easy::Easy, hdr::Union{String, SubString{String}})
    # TODO: ideally, Clang would generate Cstring signatures
    Base.unsafe_convert(Cstring, hdr) # error checking
    easy.req_hdrs = curl_slist_append(easy.req_hdrs, hdr)
    @check curl_easy_setopt(easy.handle, CURLOPT_HTTPHEADER, easy.req_hdrs)
end

add_header(easy::Easy, hdr::AbstractString) = add_header(easy, string(hdr)::String)
add_header(easy::Easy, key::AbstractString, val::AbstractString) =
    add_header(easy, isempty(val) ? "$key;" : "$key: $val")
add_header(easy::Easy, key::AbstractString, val::Nothing) =
    add_header(easy, "$key:")
add_header(easy::Easy, pair::Pair) = add_header(easy, pair...)

function add_headers(easy::Easy, headers::Union{AbstractVector, AbstractDict})
    for hdr in headers
        hdr isa Pair{<:AbstractString, <:Union{AbstractString, Nothing}} ||
            throw(ArgumentError("invalid header: $(repr(hdr))"))
        add_header(easy, hdr)
    end
end

function enable_progress(easy::Easy, on::Bool=true)
    @check curl_easy_setopt(easy.handle, CURLOPT_NOPROGRESS, !on)
end

function enable_upload(easy::Easy)
    add_upload_callbacks(easy::Easy)
    @check curl_easy_setopt(easy.handle, CURLOPT_UPLOAD, true)
end

# response info

function get_effective_url(easy::Easy)
    url_ref = Ref{Ptr{Cchar}}()
    @check curl_easy_getinfo(easy.handle, CURLINFO_EFFECTIVE_URL, url_ref)
    return unsafe_string(url_ref[])
end

function get_response_status(easy::Easy)
    code_ref = Ref{Clong}()
    @check curl_easy_getinfo(easy.handle, CURLINFO_RESPONSE_CODE, code_ref)
    return Int(code_ref[])
end

function get_response_info(easy::Easy)
    url = get_effective_url(easy)
    status = get_response_status(easy)
    message = ""
    headers = Pair{String,String}[]
    if contains(url, r"^https?://"i)
        message = isempty(easy.res_hdrs) ? "" : easy.res_hdrs[1]
        for hdr in easy.res_hdrs
            if contains(hdr, r"^\s*$")
                # ignore
            elseif (m = match(r"^(HTTP/\d+(?:.\d+)?\s+\d+\b.*?)\s*$", hdr)) !== nothing
                message = m.captures[1]
                empty!(headers)
            elseif (m = match(r"^(\S[^:]*?)\s*:\s*(.*?)\s*$", hdr)) !== nothing
                push!(headers, lowercase(m.captures[1]) => m.captures[2])
            else
                @warn "malformed HTTP header" url status header=hdr
            end
        end
    elseif contains(url, r"^s?ftps?://"i)
        message = isempty(easy.res_hdrs) ? "" : easy.res_hdrs[end]
    else
        # TODO: parse headers of other protocols
    end
    message = chomp(message)
    endswith(message, '.') && (message = chop(message))
    return url, status, message, headers
end

function get_curl_errstr(easy::Easy)
    easy.code == Curl.CURLE_OK && return ""
    errstr = easy.errbuf[1] == 0 ?
        unsafe_string(Curl.curl_easy_strerror(easy.code)) :
        GC.@preserve easy unsafe_string(pointer(easy.errbuf))
    return chomp(errstr)
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

# feed data to read_callback
function upload_data(easy::Easy, input::IO)
    while true
        data = eof(input) ? nothing : readavailable(input)
        easy.input === nothing && break
        easy.input = data
        curl_easy_pause(easy.handle, Curl.CURLPAUSE_CONT)
        wait(easy.ready)
        easy.input === nothing && break
        easy.ready = Threads.Event()
    end
end

function read_callback(
    data   :: Ptr{Cchar},
    size   :: Csize_t,
    count  :: Csize_t,
    easy_p :: Ptr{Cvoid},
)::Csize_t
    easy = unsafe_pointer_to_objref(easy_p)::Easy
    buf = easy.input
    if buf === nothing
        notify(easy.ready)
        return 0 # done uploading
    end
    if isempty(buf)
        notify(easy.ready)
        return CURL_READFUNC_PAUSE # wait for more data
    end
    n = min(size * count, length(buf))
    ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), data, buf, n)
    deleteat!(buf, 1:n)
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
    put!(easy.output, buf)
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
    put!(easy.progress, (dl_total, dl_now, ul_total, ul_now))
    return 0
end

function add_callbacks(easy::Easy)
    # pointer to easy object
    easy_p = pointer_from_objref(easy)
    @check curl_easy_setopt(easy.handle, CURLOPT_PRIVATE, easy_p)

    # pointer to error buffer
    errbuf_p = pointer(easy.errbuf)
    @check curl_easy_setopt(easy.handle, CURLOPT_ERRORBUFFER, errbuf_p)

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

function add_upload_callbacks(easy::Easy)
    # pointer to easy object
    easy_p = pointer_from_objref(easy)

    # set read callback
    read_cb = @cfunction(read_callback,
        Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
    @check curl_easy_setopt(easy.handle, CURLOPT_READFUNCTION, read_cb)
    @check curl_easy_setopt(easy.handle, CURLOPT_READDATA, easy_p)
end

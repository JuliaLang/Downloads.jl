mutable struct Easy
    handle   :: Ptr{Cvoid}
    input    :: Union{Vector{UInt8},Nothing}
    ready    :: Threads.Event
    seeker   :: Union{Function,Nothing}
    output   :: Channel{Vector{UInt8}}
    progress :: Channel{NTuple{4,Int}}
    req_hdrs :: Ptr{curl_slist_t}
    res_hdrs :: Vector{String}
    code     :: CURLcode
    errbuf   :: Vector{UInt8}
    debug    :: Union{Function,Nothing}
    consem   :: Bool
    paused   :: Bool
end

const EMPTY_BYTE_VECTOR = UInt8[]

# Bound on the number of received chunks (16KB each with libcurl's default
# buffer size) queued between the write callback and the task writing them to
# the output. When the queue is full the transfer is paused so a slow output
# doesn't make the whole body pile up in memory.
const OUTPUT_QUEUE_SIZE = Ref(1024)

# Size of the pieces a file is read in when uploading. Every piece handed to
# libcurl costs a pause/unpause cycle, which makes libcurl drop and re-register
# its socket (a new FDWatcher and task each time), so pieces should be large.
const UPLOAD_CHUNK_SIZE = 1 << 20

function Easy()
    easy = Easy(
        curl_easy_init(),
        EMPTY_BYTE_VECTOR,
        Threads.Event(),
        nothing,
        Channel{Vector{UInt8}}(OUTPUT_QUEUE_SIZE[]),
        Channel{NTuple{4,Int}}(1),
        C_NULL,
        String[],
        typemax(CURLcode),
        zeros(UInt8, CURL_ERROR_SIZE),
        nothing,
        false,
        false,
    )
    finalizer(done!, easy)
    add_callbacks(easy)
    set_defaults(easy)
    return easy
end

function done!(easy::Easy)
    connect_semaphore_release(easy)
    easy.handle == C_NULL && return
    curl_easy_cleanup(easy.handle)
    curl_slist_free_all(easy.req_hdrs)
    easy.handle = C_NULL
    return
end

# connect semaphore

# This semaphore limits the number of requests that can be in the connecting
# state at any given time, globally. Throttling this prevents libcurl from
# trying to start too many DNS resolver threads concurrently. It also helps
# ensure that not-yet-started requests get ßa chance to make some progress
# before adding more events from new requests to the system's workload.

const CONNECT_SEMAPHORE = Base.Semaphore(16) # empirically chosen (ie guessed)

function connect_semaphore_acquire(easy::Easy)
    @assert !easy.consem
    Base.acquire(CONNECT_SEMAPHORE)
    easy.consem = true
    return
end

function connect_semaphore_release(easy::Easy)
    easy.consem || return
    Base.release(CONNECT_SEMAPHORE)
    easy.consem = false
    return
end

# request options

function set_defaults(easy::Easy)
    # curl options
    setopt(easy, CURLOPT_NOSIGNAL, true)
    setopt(easy, CURLOPT_FOLLOWLOCATION, true)
    setopt(easy, CURLOPT_MAXREDIRS, 50)
    setopt(easy, CURLOPT_POSTREDIR, CURL_REDIR_POST_ALL)
    setopt(easy, CURLOPT_USERAGENT, USER_AGENT)
    setopt(easy, CURLOPT_NETRC, CURL_NETRC_OPTIONAL)
    setopt(easy, CURLOPT_COOKIEFILE, "")
    setopt(easy, CURLOPT_SSL_OPTIONS, CURLSSLOPT_REVOKE_BEST_EFFORT)
    # when several requests to the same host start together, wait for the
    # first connection to report whether it can multiplex (HTTP/2) instead of
    # opening a new connection per request
    setopt(easy, CURLOPT_PIPEWAIT, true)

    # prevent downloads that hang forever:
    # - timeout no response on connect (more than 30s)
    # - if server transmits nothing for 20s, bail out
    setopt(easy, CURLOPT_CONNECTTIMEOUT, 30)
    setopt(easy, CURLOPT_LOW_SPEED_TIME, 20)
    setopt(easy, CURLOPT_LOW_SPEED_LIMIT, 1)

    # ssh-related options
    setopt(easy, CURLOPT_SSH_PRIVATE_KEYFILE, ssh_key_path())
    setopt(easy, CURLOPT_SSH_PUBLIC_KEYFILE, ssh_pub_key_path())
    key_pass = something(ssh_key_pass(), C_NULL)
    setopt(easy, CURLOPT_KEYPASSWD, key_pass)
end

function set_ca_roots_path(easy::Easy, path::AbstractString)
    Base.unsafe_convert(Cstring, path) # error checking
    opt = isdir(path) ? CURLOPT_CAPATH : CURLOPT_CAINFO
    setopt(easy, opt, path)
end

function set_url(easy::Easy, url::Union{String, SubString{String}})
    # TODO: ideally, Clang would generate Cstring signatures
    Base.unsafe_convert(Cstring, url) # error checking
    setopt(easy, CURLOPT_URL, url)
    set_ssl_verify(easy, verify_host(url, "ssl"))
    set_ssh_verify(easy, verify_host(url, "ssh"))
    # libcurl cannot pause file:// transfers (they are done in one go without
    # the network layer), so their output queue cannot be bounded
    startswith(url, r"file:"i) && (easy.output = Channel{Vector{UInt8}}(Inf))
end
set_url(easy::Easy, url::AbstractString) = set_url(easy, String(url))

function set_ssl_verify(easy::Easy, verify::Bool)
    setopt(easy, CURLOPT_SSL_VERIFYPEER, verify)
end

function set_ssh_verify(easy::Easy, verify::Bool)
    if !verify
        setopt(easy, CURLOPT_SSH_KNOWNHOSTS, C_NULL)
    else
        file = ssh_known_hosts_file()
        setopt(easy, CURLOPT_SSH_KNOWNHOSTS, file)
    end
end

function set_method(easy::Easy, method::Union{String, SubString{String}})
    # TODO: ideally, Clang would generate Cstring signatures
    Base.unsafe_convert(Cstring, method) # error checking
    setopt(easy, CURLOPT_CUSTOMREQUEST, method)
end
set_method(easy::Easy, method::AbstractString) = set_method(easy, String(method))

function set_verbose(easy::Easy, verbose::Bool)
    setopt(easy, CURLOPT_VERBOSE, verbose)
end

function set_debug(easy::Easy, debug::Function)
    hasmethod(debug, Tuple{String,String}) ||
        throw(ArgumentError("debug callback must take (::String, ::String)"))
    easy.debug = debug
    add_debug_callback(easy)
    set_verbose(easy, true)
end

function set_debug(easy::Easy, debug::Nothing)
    easy.debug = nothing
    remove_debug_callback(easy)
end

function set_body(easy::Easy, body::Bool)
    setopt(easy, CURLOPT_NOBODY, !body)
end

function set_upload_size(easy::Easy, size::Integer)
    opt = Sys.WORD_SIZE ≥ 64 ? CURLOPT_INFILESIZE_LARGE : CURLOPT_INFILESIZE
    setopt(easy, opt, size)
end

function set_seeker(seeker::Function, easy::Easy)
    add_seek_callback(easy)
    easy.seeker = seeker
end

function set_timeout(easy::Easy, timeout::Real)
    timeout > 0 ||
        throw(ArgumentError("timeout must be positive, got $timeout"))
    if timeout ≤ typemax(Clong) ÷ 1000
        timeout_ms = round(Clong, timeout * 1000)
        setopt(easy, CURLOPT_TIMEOUT_MS, timeout_ms)
    else
        timeout = timeout ≤ typemax(Clong) ? round(Clong, timeout) : Clong(0)
        setopt(easy, CURLOPT_TIMEOUT, timeout)
    end
end

function add_header(easy::Easy, hdr::Union{String, SubString{String}})
    # TODO: ideally, Clang would generate Cstring signatures
    Base.unsafe_convert(Cstring, hdr) # error checking
    easy.req_hdrs = curl_slist_append(easy.req_hdrs, hdr)
    setopt(easy, CURLOPT_HTTPHEADER, easy.req_hdrs)
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
    setopt(easy, CURLOPT_NOPROGRESS, !on)
end

function enable_upload(easy::Easy)
    add_upload_callback(easy::Easy)
    setopt(easy, CURLOPT_UPLOAD, true)
end

# response info

function get_protocol(easy::Easy)
    proto_ref = Ref{Clong}()
    r = @check curl_easy_getinfo(easy.handle, CURLINFO_PROTOCOL, proto_ref)
    r == CURLE_UNKNOWN_OPTION && error("The `libcurl` version you are using is too old and does not include the `CURLINFO_PROTOCOL` feature. Please upgrade or use a Julia build that uses its own `libcurl` library.")
    proto = proto_ref[]
    proto == CURLPROTO_DICT   && return "dict"
    proto == CURLPROTO_FILE   && return "file"
    proto == CURLPROTO_FTP    && return "ftp"
    proto == CURLPROTO_FTPS   && return "ftps"
    proto == CURLPROTO_GOPHER && return "gopher"
    proto == CURLPROTO_HTTP   && return "http"
    proto == CURLPROTO_HTTPS  && return "https"
    proto == CURLPROTO_IMAP   && return "imap"
    proto == CURLPROTO_IMAPS  && return "imaps"
    proto == CURLPROTO_LDAP   && return "ldap"
    proto == CURLPROTO_LDAPS  && return "ldaps"
    proto == CURLPROTO_POP3   && return "pop3"
    proto == CURLPROTO_POP3S  && return "pop3s"
    proto == CURLPROTO_RTMP   && return "rtmp"
    proto == CURLPROTO_RTMPE  && return "rtmpe"
    proto == CURLPROTO_RTMPS  && return "rtmps"
    proto == CURLPROTO_RTMPT  && return "rtmpt"
    proto == CURLPROTO_RTMPTE && return "rtmpte"
    proto == CURLPROTO_RTMPTS && return "rtmpts"
    proto == CURLPROTO_RTSP   && return "rtsp"
    proto == CURLPROTO_SCP    && return "scp"
    proto == CURLPROTO_SFTP   && return "sftp"
    proto == CURLPROTO_SMB    && return "smb"
    proto == CURLPROTO_SMBS   && return "smbs"
    proto == CURLPROTO_SMTP   && return "smtp"
    proto == CURLPROTO_SMTPS  && return "smtps"
    proto == CURLPROTO_TELNET && return "telnet"
    proto == CURLPROTO_TFTP   && return "tftp"
    return nothing
end

status_2xx_ok(status::Integer) = 200 ≤ status < 300
status_zero_ok(status::Integer) = status == 0

const PROTOCOL_STATUS = Dict{String,Function}(
    "dict"   => status_2xx_ok,
    "file"   => status_zero_ok,
    "ftp"    => status_2xx_ok,
    "ftps"   => status_2xx_ok,
    "http"   => status_2xx_ok,
    "https"  => status_2xx_ok,
    "ldap"   => status_zero_ok,
    "ldaps"  => status_zero_ok,
    "pop3"   => status_2xx_ok,
    "pop3s"  => status_2xx_ok,
    "rtsp"   => status_2xx_ok,
    "scp"    => status_zero_ok,
    "sftp"   => status_zero_ok,
    "smtp"   => status_2xx_ok,
    "smtps"  => status_2xx_ok,
)

function status_ok(proto::AbstractString, status::Integer)
    test = get(PROTOCOL_STATUS, proto, nothing)
    test !== nothing && return test(status)::Bool
    error("Downloads.jl doesn't know the correct request success criterion for $proto: you can use `request` and check the `status` field yourself or open an issue with Downloads with details an example URL that you are trying to download.")
end
status_ok(proto::Nothing, status::Integer) = false

function info_type(type::curl_infotype)
    type == 0 ? "TEXT" :
    type == 1 ? "HEADER IN" :
    type == 2 ? "HEADER OUT" :
    type == 3 ? "DATA IN" :
    type == 4 ? "DATA OUT" :
    type == 5 ? "SSL DATA IN" :
    type == 6 ? "SSL DATA OUT" :
                "UNKNOWN"
end

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
    proto = get_protocol(easy)
    url = get_effective_url(easy)
    status = get_response_status(easy)
    message = ""
    headers = Pair{String,String}[]
    if proto in ("http", "https")
        message = isempty(easy.res_hdrs) ? "" : easy.res_hdrs[1]
        for hdr in easy.res_hdrs
            if contains(hdr, r"^\s*$")
                # ignore
            elseif (m = match(r"^(HTTP/\d+(?:.\d+)?\s+\d+\b.*?)\s*$", hdr); m) !== nothing
                message = m.captures[1]::SubString{String}
                empty!(headers)
            elseif (m = match(r"^(\S[^:]*?)\s*:\s*(.*?)\s*$", hdr); m) !== nothing
                key = lowercase(m.captures[1]::SubString{String})
                val = m.captures[2]::SubString{String}
                push!(headers, key => val)
            else
                @warn "malformed HTTP header" url status header=hdr
            end
        end
    elseif proto in ("ftp", "ftps", "sftp")
        message = isempty(easy.res_hdrs) ? "" : easy.res_hdrs[end]
    else
        # TODO: parse headers of other protocols
    end
    message = chomp(message)
    endswith(message, '.') && (message = chop(message))
    return proto, url, status, message, headers
end

function get_curl_errstr(easy::Easy)
    easy.code == Curl.CURLE_OK && return ""
    errstr = easy.errbuf[1] == 0 ?
        unsafe_string(Curl.curl_easy_strerror(easy.code)) :
        GC.@preserve easy unsafe_string(pointer(easy.errbuf))
    return chomp(errstr)
end

# callbacks

function prereq_callback(
    easy_p           :: Ptr{Cvoid},
    conn_remote_ip   :: Ptr{Cchar},
    conn_local_ip    :: Ptr{Cchar},
    conn_remote_port :: Cint,
    conn_local_port  :: Cint,
)::Cint
    easy = unsafe_pointer_to_objref(easy_p)::Easy
    connect_semaphore_release(easy)
    return 0
end

function header_callback(
    data   :: Ptr{Cchar},
    size   :: Csize_t,
    count  :: Csize_t,
    easy_p :: Ptr{Cvoid},
)::Csize_t
    try
        easy = unsafe_pointer_to_objref(easy_p)::Easy
        n = size * count
        hdr = unsafe_string(data, n)
        push!(easy.res_hdrs, hdr)
        return n
    catch err
        @async @error("header_callback: unexpected error", err=err, maxlog=1_000)
        return typemax(Csize_t)
    end
end

# `readavailable` on an IOStream returns at most its 32KB buffer, which for a
# file means a pause/unpause cycle per 32KB; read big pieces instead.
read_chunk(input::IO) = readavailable(input)
function read_chunk(input::IOStream)
    buf = Vector{UInt8}(undef, UPLOAD_CHUNK_SIZE)
    n = readbytes!(input, buf, UPLOAD_CHUNK_SIZE, all=false)
    return resize!(buf, n)
end

# feed data to read_callback
function upload_data(easy::Easy, input::IO)
    while true
        data = eof(input) ? nothing : read_chunk(input)
        easy.input === nothing && break
        easy.input = data
        curl_easy_pause(easy.handle, Curl.CURLPAUSE_CONT)
        wait(easy.ready)
        easy.input === nothing && break
        if hasmethod(reset, (Base.Event,))
            reset(easy.ready)
        else
            easy.ready = Threads.Event()
        end
    end
end

function read_callback(
    data   :: Ptr{Cchar},
    size   :: Csize_t,
    count  :: Csize_t,
    easy_p :: Ptr{Cvoid},
)::Csize_t
    try
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
    catch err
        @async @error("read_callback: unexpected error", err=err, maxlog=1_000)
        return CURL_READFUNC_ABORT
    end
end

function seek_callback(
    easy_p :: Ptr{Cvoid},
    offset :: curl_off_t,
    origin :: Cint,
)::Cint
    try
        if origin != 0
            @async @error("seek_callback: unsupported seek origin", origin, maxlog=1_000)
            return CURL_SEEKFUNC_CANTSEEK
        end
        easy = unsafe_pointer_to_objref(easy_p)::Easy
        easy.seeker === nothing && return CURL_SEEKFUNC_CANTSEEK
        try easy.seeker(offset)
        catch err
            @async @error("seek_callback: seeker failed", err, maxlog=1_000)
            return CURL_SEEKFUNC_FAIL
        end
        return CURL_SEEKFUNC_OK
    catch err
        @async @error("seek_callback: unexpected error", err=err, maxlog=1_000)
        return CURL_SEEKFUNC_FAIL
    end
end

function write_callback(
    data   :: Ptr{Cchar},
    size   :: Csize_t,
    count  :: Csize_t,
    easy_p :: Ptr{Cvoid},
)::Csize_t
    try
        easy = unsafe_pointer_to_objref(easy_p)::Easy
        n = size * count
        # the check and the flag update share the channel lock so that the
        # consumer, which reads the flag after each `take!`, cannot drain the
        # queue between them and then wait forever on a paused transfer
        paused = lock(easy.output) do
            easy.paused = Base.n_avail(easy.output) >= easy.output.sz_max
        end
        # libcurl keeps the data and delivers it again once unpaused
        paused && return CURL_WRITEFUNC_PAUSE
        buf = Array{UInt8}(undef, n)
        ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), buf, data, n)
        put!(easy.output, buf)
        return n
    catch err
        @async @error("write_callback: unexpected error", err=err, maxlog=1_000)
        return typemax(Csize_t)
    end
end

function progress_callback(
    easy_p   :: Ptr{Cvoid},
    dl_total :: curl_off_t,
    dl_now   :: curl_off_t,
    ul_total :: curl_off_t,
    ul_now   :: curl_off_t,
)::Cint
    try
        easy = unsafe_pointer_to_objref(easy_p)::Easy
        # libcurl reports progress on every socket read; only the most recent
        # report is kept so that a slow progress callback sees current numbers
        # instead of working through a backlog of stale ones
        lock(easy.progress) do
            isready(easy.progress) && take!(easy.progress)
            put!(easy.progress, (dl_total, dl_now, ul_total, ul_now))
        end
        return 0
    catch err
        @async @error("progress_callback: unexpected error", err=err, maxlog=1_000)
        return -1
    end
end

function debug_callback(
    handle :: Ptr{Cvoid},
    type   :: curl_infotype,
    data   :: Ptr{Cchar},
    size   :: Csize_t,
    easy_p :: Ptr{Cvoid},
)::Cint
    try
        easy = unsafe_pointer_to_objref(easy_p)::Easy
        @assert easy.handle == handle
        easy.debug(info_type(type), unsafe_string(data, size))
        return 0
    catch err
        @async @error("debug_callback: unexpected error", err=err, maxlog=1_000)
        return -1
    end
end

function add_callbacks(easy::Easy)
    # pointer to easy object
    easy_p = pointer_from_objref(easy)
    setopt(easy, CURLOPT_PRIVATE, easy_p)

    # pointer to error buffer
    errbuf_p = pointer(easy.errbuf)
    setopt(easy, CURLOPT_ERRORBUFFER, errbuf_p)

    # set pre-request callback
    prereq_cb = @cfunction(prereq_callback,
        Cint, (Ptr{Cvoid}, Ptr{Cchar}, Ptr{Cchar}, Cint, Cint))
    setopt(easy, CURLOPT_PREREQFUNCTION, prereq_cb)
    setopt(easy, CURLOPT_PREREQDATA, easy_p)

    # set header callback
    header_cb = @cfunction(header_callback,
        Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
    setopt(easy, CURLOPT_HEADERFUNCTION, header_cb)
    setopt(easy, CURLOPT_HEADERDATA, easy_p)

    # set write callback
    write_cb = @cfunction(write_callback,
        Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
    setopt(easy, CURLOPT_WRITEFUNCTION, write_cb)
    setopt(easy, CURLOPT_WRITEDATA, easy_p)

    # set progress callback
    progress_cb = @cfunction(progress_callback,
        Cint, (Ptr{Cvoid}, curl_off_t, curl_off_t, curl_off_t, curl_off_t))
    setopt(easy, CURLOPT_XFERINFOFUNCTION, progress_cb)
    setopt(easy, CURLOPT_XFERINFODATA, easy_p)
end

function add_upload_callback(easy::Easy)
    # pointer to easy object
    easy_p = pointer_from_objref(easy)

    # set read callback
    read_cb = @cfunction(read_callback,
        Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
    setopt(easy, CURLOPT_READFUNCTION, read_cb)
    setopt(easy, CURLOPT_READDATA, easy_p)
end

function add_seek_callback(easy::Easy)
    # pointer to easy object
    easy_p = pointer_from_objref(easy)

    # set seek callback
    seek_cb = @cfunction(seek_callback,
        Cint, (Ptr{Cvoid}, curl_off_t, Cint))
    setopt(easy, CURLOPT_SEEKFUNCTION, seek_cb)
    setopt(easy, CURLOPT_SEEKDATA, easy_p)
end

function add_debug_callback(easy::Easy)
    # pointer to easy object
    easy_p = pointer_from_objref(easy)

    # set debug callback
    debug_cb = @cfunction(debug_callback,
        Cint, (Ptr{Cvoid}, curl_infotype, Ptr{Cchar}, Csize_t, Ptr{Cvoid}))
    setopt(easy, CURLOPT_DEBUGFUNCTION, debug_cb)
    setopt(easy, CURLOPT_DEBUGDATA, easy_p)
end

function remove_debug_callback(easy::Easy)
    setopt(easy, CURLOPT_DEBUGFUNCTION, C_NULL)
    setopt(easy, CURLOPT_DEBUGDATA, C_NULL)
end

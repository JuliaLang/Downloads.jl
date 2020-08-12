# curl callbacks

function write_callback(
    ptr   :: Ptr{Cchar},
    size  :: Csize_t,
    count :: Csize_t,
    io_p  :: Ptr{Cvoid},
)::Csize_t
    n = size * count
    buffer = Array{UInt8}(undef, n)
    ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), buffer, ptr, n)
    io = unsafe_pointer_to_objref(io_p)::IO
    @async write(io, buffer)
    return n
end

const POLL_TO_CURL = IdDict{Ptr{Cvoid},Curl}()

function socket_callback(
    easy      :: Ptr{Cvoid},
    sock      :: curl_socket_t,
    action    :: Cint,
    curl_p    :: Ptr{Cvoid},
    uv_poll_p :: Ptr{Cvoid},
)::Cint
    curl = unsafe_pointer_to_objref(curl_p)::Curl
    if action in (CURL_POLL_IN, CURL_POLL_OUT, CURL_POLL_INOUT)
        if uv_poll_p == C_NULL
            uv_poll_p = uv_poll_alloc()
            uv_poll_init(uv_poll_p, sock)
            @check curl_multi_assign(curl.multi, sock, uv_poll_p)
            # TODO: should be a member lookup
            unsafe_store!(convert(Ptr{curl_socket_t}, uv_poll_p), sock)
            POLL_TO_CURL[uv_poll_p] = curl
        end
        events = 0
        action != CURL_POLL_IN  && (events |= UV_WRITABLE)
        action != CURL_POLL_OUT && (events |= UV_READABLE)
        uv_poll_start(uv_poll_p, events, event_cb)
    elseif action == CURL_POLL_REMOVE
        if uv_poll_p != C_NULL
            uv_poll_stop(uv_poll_p)
            uv_close(uv_poll_p, cglobal(:jl_free))
            @check curl_multi_assign(curl.multi, sock, C_NULL)
            delete!(POLL_TO_CURL, uv_poll_p)
        end
    else
        @async @error("socket_callback: unexpected action", action)
    end
    return 0
end

function timer_callback(
    multi      :: Ptr{Cvoid},
    timeout_ms :: Clong,
    curl_p     :: Ptr{Cvoid},
)::Cint
    curl = unsafe_pointer_to_objref(curl_p)::Curl
    if timeout_ms ≥ 0
        uv_timer_start(curl.timer, timeout_cb, max(1, timeout_ms), 0)
    else
        uv_timer_stop(curl.timer)
    end
    return 0
end

const write_cb = @cfunction(write_callback,
    Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
const socket_cb = @cfunction(socket_callback,
    Cint, (Ptr{Cvoid}, curl_socket_t, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
const timer_cb = @cfunction(timer_callback,
    Cint, (Ptr{Cvoid}, Clong, Ptr{Cvoid}))

# libuv callbacks

struct CURLMsg
   msg  :: CURLMSG
   easy :: Ptr{Cvoid}
   code :: CURLcode
end

function check_multi_info(curl::Curl)
    while true
        p = curl_multi_info_read(curl.multi, Ref{Cint}())
        p == C_NULL && return
        message = unsafe_load(convert(Ptr{CURLMsg}, p))
        if message.msg == CURLMSG_DONE
            easy = message.easy
            url_ref = Ref{Ptr{Cchar}}()
            @check curl_easy_getinfo(easy, CURLINFO_EFFECTIVE_URL, url_ref)
            url = unsafe_string(url_ref[])
            msg = unsafe_string(curl_easy_strerror(message.code))
            @async @info("request done", url, msg, code = Int(message.code))
            @check curl_multi_remove_handle(curl.multi, easy)
            curl_easy_cleanup(easy)
        else
            @async @info("unknown Curl message type", msg = message.msg)
        end
    end
end

function event_callback(
    uv_poll_p :: Ptr{Cvoid},
    status    :: Cint,
    events    :: Cint,
)::Cvoid
    curl = POLL_TO_CURL[uv_poll_p]
    # TODO: should be a member lookup
    sock = unsafe_load(convert(Ptr{curl_socket_t}, uv_poll_p))
    flags = 0
    events & UV_READABLE != 0 && (flags |= CURL_CSELECT_IN)
    events & UV_WRITABLE != 0 && (flags |= CURL_CSELECT_OUT)
    @check curl_multi_socket_action(curl.multi, sock, flags)
    check_multi_info(curl)
end

function timeout_callback(uv_timer_p::Ptr{Cvoid})::Cvoid
    curl_p = uv_timer_p # TODO: should be member lookup
    curl = unsafe_pointer_to_objref(uv_timer_p)::Curl
    @check curl_multi_socket_action(curl.multi, CURL_SOCKET_TIMEOUT, 0)
    check_multi_info(curl)
end

const event_cb = @cfunction(event_callback, Cvoid, (Ptr{Cvoid}, Cint, Cint))
const timeout_cb = @cfunction(timeout_callback, Cvoid, (Ptr{Cvoid},))

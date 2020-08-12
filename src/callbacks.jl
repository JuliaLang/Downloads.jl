# libuv callbacks

struct CURLMsg
   msg    :: CURLMSG
   handle :: Ptr{Cvoid}
   code   :: CURLcode
end

function check_multi_info()
    while true
        p = curl_multi_info_read(curl, Ref{Cint}())
        p == C_NULL && return
        message = unsafe_load(convert(Ptr{CURLMsg}, p))
        if message.msg == CURLMSG_DONE
            handle = message.handle
            url_ref = Ref{Ptr{Cchar}}()
            @check curl_easy_getinfo(handle, CURLINFO_EFFECTIVE_URL, url_ref)
            url = unsafe_string(url_ref[])
            msg = unsafe_string(curl_easy_strerror(message.code))
            @async @info("request done", url, msg, code = Int(message.code))
            @check curl_multi_remove_handle(curl, handle)
            curl_easy_cleanup(handle)
        else
            @async @info("unknown CURL message type", msg = message.msg)
        end
    end
end

function event_callback(
    uv_poll_p :: Ptr{Cvoid},
    status    :: Cint,
    events    :: Cint,
)::Cvoid
    flags = 0
    events & UV_READABLE != 0 && (flags |= CURL_CSELECT_IN)
    events & UV_WRITABLE != 0 && (flags |= CURL_CSELECT_OUT)
    sock = unsafe_load(convert(Ptr{curl_socket_t}, uv_poll_p))
    @check curl_multi_socket_action(curl, sock, flags)
    check_multi_info()
end

function timeout_callback(p::Ptr{Cvoid})::Cvoid
    @check curl_multi_socket_action(curl, CURL_SOCKET_TIMEOUT, 0)
    check_multi_info()
end

# curl callbacks

function write_callback(
    ptr   :: Ptr{Cchar},
    size  :: Csize_t,
    count :: Csize_t,
    userp :: Ptr{Cvoid},
)::Csize_t
    n = size * count
    # ccall(:write, Csize_t, (Cint, Ptr{Cvoid}, Csize_t), 1, ptr, n)
    buffer = Array{UInt8}(undef, n)
    ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), buffer, ptr, n)
    io = unsafe_pointer_to_objref(userp)::IO
    @async write(io, buffer)
    return n
end

function socket_callback(
    handle    :: Ptr{Cvoid},
    sock      :: curl_socket_t,
    action    :: Cint,
    userp     :: Ptr{Cvoid},
    uv_poll_p :: Ptr{Cvoid},
)::Cint
    if action in (CURL_POLL_IN, CURL_POLL_OUT, CURL_POLL_INOUT)
        if uv_poll_p == C_NULL
            uv_poll_p = uv_poll_alloc()
            uv_poll_init(uv_poll_p, sock)
            # NOTE: if assertion fails need to store indirectly
            @assert sizeof(curl_socket_t) <= sizeof(Ptr{Cvoid})
            unsafe_store!(convert(Ptr{curl_socket_t}, uv_poll_p), sock)
            @check curl_multi_assign(curl, sock, uv_poll_p)
        end
        events = 0
        action != CURL_POLL_IN  && (events |= UV_WRITABLE)
        action != CURL_POLL_OUT && (events |= UV_READABLE)
        event_cb = @cfunction(event_callback, Cvoid, (Ptr{Cvoid}, Cint, Cint))
        uv_poll_start(uv_poll_p, events, event_cb)
    elseif action == CURL_POLL_REMOVE
        if uv_poll_p != C_NULL
            uv_poll_stop(uv_poll_p)
            uv_close(uv_poll_p, cglobal(:jl_free))
            @check curl_multi_assign(curl, sock, C_NULL)
        end
    else
        @async @error("socket_callback: unexpected action", action)
    end
    return 0
end

function timer_callback(
    multi      :: Ptr{Cvoid},
    timeout_ms :: Clong,
    userp      :: Ptr{Cvoid},
)::Cint
    if timeout_ms ≥ 0
        timeout_cb = @cfunction(timeout_callback, Cvoid, (Ptr{Cvoid},))
        uv_timer_start(timer, timeout_cb, max(1, timeout_ms), 0)
    else
        uv_timer_stop(timer)
    end
    return 0
end

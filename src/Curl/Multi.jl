mutable struct Multi
    handle :: Ptr{Cvoid}
    timer  :: Ptr{Cvoid}
end

function Multi()
    timer = jl_malloc(Base._sizeof_uv_timer)
    uv_timer_init(timer)
    multi = Multi(curl_multi_init(), timer)
    finalizer(multi) do multi
        uv_close(multi.timer, cglobal(:jl_free))
        curl_multi_cleanup(multi.handle)
    end
    add_callbacks(multi)
    return multi
end

# libuv callbacks

struct CURLMsg
   msg  :: CURLMSG
   easy :: Ptr{Cvoid}
   code :: CURLcode
end

function check_multi_info(multi::Multi)
    while true
        p = curl_multi_info_read(multi.handle, Ref{Cint}())
        p == C_NULL && return
        message = unsafe_load(convert(Ptr{CURLMsg}, p))
        if message.msg == CURLMSG_DONE
            easy_handle = message.easy
            easy_p_ref = Ref{Ptr{Cvoid}}()
            @check curl_easy_getinfo(easy_handle, CURLINFO_PRIVATE, easy_p_ref)
            easy = unsafe_pointer_to_objref(easy_p_ref[])::Easy
            @assert easy_handle == easy.handle
            easy.code = message.code
            close(easy.progress)
            close(easy.buffers)
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
    ## TODO: use a member access API
    multi_p = unsafe_load(convert(Ptr{Ptr{Cvoid}}, uv_poll_p))
    multi = unsafe_pointer_to_objref(multi_p)::Multi
    sock_p = uv_poll_p + Base._sizeof_uv_poll
    sock = unsafe_load(convert(Ptr{curl_socket_t}, sock_p))
    flags = 0
    events & UV_READABLE != 0 && (flags |= CURL_CSELECT_IN)
    events & UV_WRITABLE != 0 && (flags |= CURL_CSELECT_OUT)
    @check curl_multi_socket_action(multi.handle, sock, flags)
    check_multi_info(multi)
end

function timeout_callback(uv_timer_p::Ptr{Cvoid})::Cvoid
    ## TODO: use a member access API
    multi_p = unsafe_load(convert(Ptr{Ptr{Cvoid}}, uv_timer_p))
    multi = unsafe_pointer_to_objref(multi_p)::Multi
    @check curl_multi_socket_action(multi.handle, CURL_SOCKET_TIMEOUT, 0)
    check_multi_info(multi)
end

# curl callbacks

function timer_callback(
    handle_p   :: Ptr{Cvoid},
    timeout_ms :: Clong,
    multi_p    :: Ptr{Cvoid},
)::Cint
    multi = unsafe_pointer_to_objref(multi_p)::Multi
    @assert handle_p == multi.handle
    if timeout_ms == 0
        @check curl_multi_socket_action(multi.handle, CURL_SOCKET_TIMEOUT, 0)
    end
    if timeout_ms > 0
        timeout_cb = @cfunction(timeout_callback, Cvoid, (Ptr{Cvoid},))
        uv_timer_start(multi.timer, timeout_cb, timeout_ms, 0)
    else
        uv_timer_stop(multi.timer)
    end
    check_multi_info(multi)
    return 0
end

function socket_callback(
    easy      :: Ptr{Cvoid},
    sock      :: curl_socket_t,
    action    :: Cint,
    multi_p    :: Ptr{Cvoid},
    uv_poll_p :: Ptr{Cvoid},
)::Cint
    multi = unsafe_pointer_to_objref(multi_p)::Multi
    if action in (CURL_POLL_IN, CURL_POLL_OUT, CURL_POLL_INOUT)
        if uv_poll_p == C_NULL
            uv_poll_p = uv_poll_alloc()
            uv_poll_init(uv_poll_p, sock)
            ## TODO: use a member access API
            unsafe_store!(convert(Ptr{Ptr{Cvoid}}, uv_poll_p), multi_p)
            sock_p = uv_poll_p + Base._sizeof_uv_poll
            unsafe_store!(convert(Ptr{curl_socket_t}, sock_p), sock)
            @check curl_multi_assign(multi.handle, sock, uv_poll_p)
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
            @check curl_multi_assign(multi.handle, sock, C_NULL)
        end
    else
        @async @error("socket_callback: unexpected action", action)
    end
    return 0
end

function add_callbacks(multi::Multi)
    # stash multi handle pointer in timer
    multi_p = pointer_from_objref(multi)
    ## TODO: use a member access API
    unsafe_store!(convert(Ptr{Ptr{Cvoid}}, multi.timer), multi_p)

    # set timer callback
    timer_cb = @cfunction(timer_callback, Cint, (Ptr{Cvoid}, Clong, Ptr{Cvoid}))
    @check curl_multi_setopt(multi.handle, CURLMOPT_TIMERFUNCTION, timer_cb)
    @check curl_multi_setopt(multi.handle, CURLMOPT_TIMERDATA, multi_p)

    # set socket callback
    socket_cb = @cfunction(socket_callback,
        Cint, (Ptr{Cvoid}, curl_socket_t, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
    @check curl_multi_setopt(multi.handle, CURLMOPT_SOCKETFUNCTION, socket_cb)
    @check curl_multi_setopt(multi.handle, CURLMOPT_SOCKETDATA, multi_p)
end

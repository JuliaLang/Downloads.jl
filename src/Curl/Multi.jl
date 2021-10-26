mutable struct Multi
    lock   :: ReentrantLock
    handle :: Ptr{Cvoid}
    timer  :: Timer
    easies :: Vector{Easy}
    grace  :: UInt64

    function Multi(grace::Integer = typemax(UInt64))
        multi = new(ReentrantLock(), C_NULL, Timer(0), Easy[], grace)
        finalizer(multi) do multi
            close(multi.timer)
            done!(multi)
        end
    end
end

function init!(multi::Multi)
    multi.handle != C_NULL && return
    multi.handle = curl_multi_init()
    add_callbacks(multi)
    set_defaults(multi)
end

function done!(multi::Multi)
    multi.handle == C_NULL && return
    curl_multi_cleanup(multi.handle)
    multi.handle = C_NULL
end

# adding & removing easy handles

function add_handle(multi::Multi, easy::Easy)
    lock(multi.lock) do
        if isempty(multi.easies)
            preserve_handle(multi)
            close(multi.timer) # stop grace timer
        end
        push!(multi.easies, easy)
        init!(multi)
        @check curl_multi_add_handle(multi.handle, easy.handle)
    end
end

function remove_handle(multi::Multi, easy::Easy)
    lock(multi.lock) do
        @check curl_multi_remove_handle(multi.handle, easy.handle)
        deleteat!(multi.easies, findlast(==(easy), multi.easies)::Int)
        !isempty(multi.easies) && return
        if multi.grace <= 0
            done!(multi)
        elseif 0 < multi.grace < typemax(multi.grace)
            multi.timer = Timer(multi.grace/1000)
            @async begin
                wait(multi.timer)
                isopen(multi.timer) && done!(multi)
            end
        end
        unpreserve_handle(multi)
    end
end

# multi-socket options

function set_defaults(multi::Multi)
    # currently no defaults
end

# multi-socket handle state updates

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
            close(easy.output)
            easy.input = nothing
            notify(easy.ready)
        else
            @async @error("curl_multi_info_read: unknown message", message)
        end
    end
end

# curl callbacks

function do_multi(multi::Multi)
    lock(multi.lock) do
        @check curl_multi_socket_action(multi.handle, CURL_SOCKET_TIMEOUT, 0)
        check_multi_info(multi)
    end
end

function timer_callback(
    multi_h    :: Ptr{Cvoid},
    timeout_ms :: Clong,
    multi_p    :: Ptr{Cvoid},
)::Cint
    multi = unsafe_pointer_to_objref(multi_p)::Multi
    @assert multi_h == multi.handle
    if timeout_ms == 0
        do_multi(multi)
    elseif timeout_ms >= 0
        multi.timer = Timer(timeout_ms/1000) do timer
            do_multi(multi)
        end
    elseif timeout_ms == -1
        close(multi.timer)
    else
        @async @error("timer_callback: invalid timeout value", timeout_ms)
        return -1
    end
    return 0
end

function socket_callback(
    easy_h    :: Ptr{Cvoid},
    sock      :: curl_socket_t,
    action    :: Cint,
    multi_p   :: Ptr{Cvoid},
    watcher_p :: Ptr{Cvoid},
)::Cint
    if action ∉ (CURL_POLL_IN, CURL_POLL_OUT, CURL_POLL_INOUT, CURL_POLL_REMOVE)
        @async @error("socket_callback: unexpected action", action)
        return -1
    end
    multi = unsafe_pointer_to_objref(multi_p)::Multi
    if watcher_p != C_NULL
        old_watcher = unsafe_pointer_to_objref(watcher_p)::FDWatcher
        @check curl_multi_assign(multi.handle, sock, C_NULL)
        unpreserve_handle(old_watcher)
    end
    if action in (CURL_POLL_IN, CURL_POLL_OUT, CURL_POLL_INOUT)
        readable = action in (CURL_POLL_IN,  CURL_POLL_INOUT)
        writable = action in (CURL_POLL_OUT, CURL_POLL_INOUT)
        watcher = FDWatcher(OS_HANDLE(sock), readable, writable)
        preserve_handle(watcher)
        watcher_p = pointer_from_objref(watcher)
        @check curl_multi_assign(multi.handle, sock, watcher_p)
        task = @async while true
            events = try wait(watcher)
            catch err
                err isa EOFError && break
                rethrow()
            end
            flags = CURL_CSELECT_IN  * isreadable(events) +
                    CURL_CSELECT_OUT * iswritable(events) +
                    CURL_CSELECT_ERR * events.disconnect
            lock(multi.lock) do
                @check curl_multi_socket_action(multi.handle, sock, flags)
                check_multi_info(multi)
            end
        end
        @isdefined(errormonitor) && errormonitor(task)
    end
    @isdefined(old_watcher) && close(old_watcher)
    return 0
end

function add_callbacks(multi::Multi)
    multi_p = pointer_from_objref(multi)

    # set timer callback
    timer_cb = @cfunction(timer_callback, Cint, (Ptr{Cvoid}, Clong, Ptr{Cvoid}))
    setopt(multi, CURLMOPT_TIMERFUNCTION, timer_cb)
    setopt(multi, CURLMOPT_TIMERDATA, multi_p)

    # set socket callback
    socket_cb = @cfunction(socket_callback,
        Cint, (Ptr{Cvoid}, curl_socket_t, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
    setopt(multi, CURLMOPT_SOCKETFUNCTION, socket_cb)
    setopt(multi, CURLMOPT_SOCKETDATA, multi_p)
end

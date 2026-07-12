mutable struct Multi
    lock   :: ReentrantLock
    handle :: Ptr{Cvoid}
    timer  :: Union{Nothing,Timer}
    easies :: Vector{Easy}
    grace  :: UInt64
    failed    :: Bool
    recovered :: Base.Event

    function Multi(grace::Integer = typemax(UInt64))
        recovered = Base.Event()
        notify(recovered)
        multi = new(ReentrantLock(), C_NULL, nothing, Easy[], grace, false, recovered)
        finalizer(done!, multi)
        @lock MULTIS_LOCK push!(filter!(m -> m.value isa Multi, MULTIS), WeakRef(multi))
        return multi
    end
end

function init!(multi::Multi)
    multi.handle != C_NULL && return
    multi.handle = curl_multi_init()
    add_callbacks(multi)
    set_defaults(multi)
    nothing
end

function done!(multi::Multi)
    stoptimer!(multi)
    handle = multi.handle
    handle == C_NULL && return
    # Starting from LibCURL v8.10 we have to keep the handle non-NULL before calling the
    # cleanup function (<https://github.com/JuliaLang/Downloads.jl/issues/260>), but doing
    # so with Curl v8.10 causes an assertion failure
    # (<https://github.com/JuliaLang/Downloads.jl/issues/260#issuecomment-2452772273>),
    # that's fixed only with curl 8.11.
    @static if CURL_VERSION < v"8.11"
        multi.handle = C_NULL
        curl_multi_cleanup(handle)
    else
        curl_multi_cleanup(handle)
        multi.handle = C_NULL
    end
    nothing
end

function stoptimer!(multi::Multi)
    t = multi.timer
    if t !== nothing
        multi.timer = nothing
        close(t)
    end
    nothing
end

# adding & removing easy handles

function add_handle(multi::Multi, easy::Easy)
    connect_semaphore_acquire(easy)
    added = lock(multi.lock) do
        if multi.failed
            abort_easy!(easy)
            return false
        end
        init!(multi)
        code = curl_multi_add_handle(multi.handle, easy.handle)
        if code != CURLM_OK
            fail_multi!(multi, :curl_multi_add_handle, code)
            abort_easy!(easy)
            return false
        end
        isempty(multi.easies) && preserve_handle(multi)
        push!(multi.easies, easy)
        return true
    end
    added || connect_semaphore_release(easy)
end

const MULTIS_LOCK = Base.ReentrantLock()
const MULTIS = WeakRef[]

function remove_handle(multi::Multi, easy::Easy)
    while true
        recovered = lock(multi.lock) do
            i = findlast(==(easy), multi.easies)
            i === nothing && return nothing
            multi.failed && return multi.recovered
            code = curl_multi_remove_handle(multi.handle, easy.handle)
            if code != CURLM_OK
                fail_multi!(multi, :curl_multi_remove_handle, code)
                return multi.recovered
            end
            deleteat!(multi.easies, i)
            isempty(multi.easies) || return nothing
            stoptimer!(multi)
            if multi.grace <= 0
                done!(multi)
            elseif 0 < multi.grace < typemax(multi.grace)
                multi.timer = Timer(multi.grace/1000) do timer
                    expire_multi!(multi, timer)
                end
            end
            unpreserve_handle(multi)
            return nothing
        end
        recovered === nothing && break
        wait(recovered)
    end
    connect_semaphore_release(easy)
end

function expire_multi!(multi::Multi, timer::Timer)
    lock(multi.lock) do
        multi.timer === timer || return
        multi.timer = nothing
        isempty(multi.easies) || return
        done!(multi)
    end
end

# multi-socket options

function set_defaults(multi::Multi)
    # currently no defaults
end

# feed data to read_callback
function upload_data(multi::Multi, easy::Easy, input::IO)
    while true
        data = eof(input) ? nothing : readavailable(input)
        stopped = lock(multi.lock) do
            easy.input === nothing && return true
            easy.input = data
            # Unpausing can invoke multi callbacks before returning.
            curl_easy_pause(easy.handle, Curl.CURLPAUSE_CONT)
            return false
        end
        stopped && break
        wait(easy.ready)
        easy.input === nothing && break
        if hasmethod(reset, (Base.Event,))
            reset(easy.ready)
        else
            easy.ready = Threads.Event()
        end
    end
end

# multi-socket handle state updates

function abort_easy!(easy::Easy)
    easy.code = CURLE_ABORTED_BY_CALLBACK
    close(easy.progress)
    close(easy.output)
    easy.input = nothing
    notify(easy.ready)
    nothing
end

function fail_multi!(multi::Multi, operation::Symbol, code::CURLMcode)
    multi.failed && return
    multi.failed = true
    reset(multi.recovered)
    # Recover after returning from the libcurl callback stack.
    task = @async recover_multi!(multi, operation, code)
    @isdefined(errormonitor) && errormonitor(task)
    nothing
end

function recover_multi!(multi::Multi, operation::Symbol, code::CURLMcode)
    @error "$operation: $code" maxlog=1_000
    while true
        retry = lock(multi.lock) do
            multi.failed || return false
            for easy in multi.easies
                result = curl_multi_remove_handle(multi.handle, easy.handle)
                # A callback may yield after scheduling recovery.
                result == CURLM_RECURSIVE_API_CALL && return true
                result == CURLM_OK || error("curl_multi_remove_handle: $result")
            end
            easies = copy(multi.easies)
            empty!(multi.easies)
            isempty(easies) || unpreserve_handle(multi)
            stoptimer!(multi)
            done!(multi)
            for easy in easies
                abort_easy!(easy)
                connect_semaphore_release(easy)
            end
            multi.failed = false
            notify(multi.recovered)
            return false
        end
        retry || return
        yield()
    end
end

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
            close(easy.output)
            easy.input = nothing
            notify(easy.ready)
        else
            @async @error("curl_multi_info_read: unknown message", message, maxlog=1_000)
        end
    end
end

# curl callbacks

function do_multi(multi::Multi)
    multi.failed && return
    code = curl_multi_socket_action(multi.handle, CURL_SOCKET_TIMEOUT, 0)
    if code != CURLM_OK
        fail_multi!(multi, :curl_multi_socket_action, code)
        return
    end
    check_multi_info(multi)
end

function timer_callback(
    multi_h    :: Ptr{Cvoid},
    timeout_ms :: Clong,
    multi_p    :: Ptr{Cvoid},
)::Cint
    try
        multi = unsafe_pointer_to_objref(multi_p)::Multi
        @assert multi_h == multi.handle
        stoptimer!(multi)
        if timeout_ms >= 0
            multi.timer = Timer(timeout_ms/1000) do timer
                lock(multi.lock) do
                    multi.timer === timer || return
                    multi.timer = nothing
                    do_multi(multi)
                end
            end
        elseif timeout_ms != -1
            @async @error("timer_callback: invalid timeout value", timeout_ms, maxlog=1_000)
            return -1
        end
        return 0
    catch err
        @async @error("timer_callback: unexpected error", err=err, maxlog=1_000)
        return -1
    end
end

function socket_callback(
    easy_h    :: Ptr{Cvoid},
    sock      :: curl_socket_t,
    action    :: Cint,
    multi_p   :: Ptr{Cvoid},
    watcher_p :: Ptr{Cvoid},
)::Cint
    try
        if action ∉ (CURL_POLL_IN, CURL_POLL_OUT, CURL_POLL_INOUT, CURL_POLL_REMOVE)
            @async @error("socket_callback: unexpected action", action, maxlog=1_000)
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
            task = @async while watcher.readable || watcher.writable # isopen(watcher)
                events = try
                    wait(watcher)
                catch err
                    err isa EOFError && return
                    err isa Base.IOError || rethrow()
                    FileWatching.FDEvent()
                end
                flags = CURL_CSELECT_IN  * isreadable(events) +
                        CURL_CSELECT_OUT * iswritable(events) +
                        CURL_CSELECT_ERR * (events.disconnect || events.timedout)
                lock(multi.lock) do
                    multi.failed && return
                    watcher.readable || watcher.writable || return # !isopen
                    code = curl_multi_socket_action(multi.handle, sock, flags)
                    if code != CURLM_OK
                        fail_multi!(multi, :curl_multi_socket_action, code)
                        return
                    end
                    check_multi_info(multi)
                end
            end
            @isdefined(errormonitor) && errormonitor(task)
        else
            lock(multi.lock) do
                check_multi_info(multi)
            end
        end
        @isdefined(old_watcher) && close(old_watcher)
        return 0
    catch err
        @async @error("socket_callback: unexpected error", err=err, maxlog=1_000)
        return -1
    end
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

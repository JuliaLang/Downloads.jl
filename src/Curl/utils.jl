# basic C stuff

if !@isdefined(contains)
    contains(haystack, needle) = occursin(needle, haystack)
    export contains
end

puts(s::Union{String,SubString{String}}) = ccall(:puts, Cint, (Ptr{Cchar},), s)

jl_malloc(n::Integer) = ccall(:jl_malloc, Ptr{Cvoid}, (Csize_t,), n)

# check if a function or C call failed

function check(ex::Expr, lock::Bool)
    ex.head == :call ||
        error("@check: not a call: $ex")
    if ex.args[1] == :ccall
        ex.args[2] isa QuoteNode ||
            error("@check: ccallee must be a symbol")
        f = ex.args[2].value :: Symbol
    else
        f = ex.args[1] :: Symbol
    end
    prefix = "$f: "
    ex = esc(ex)
    if lock
        ex = quote
            Base.iolock_begin()
            value = $ex
            Base.iolock_end()
            value
        end
    end
    quote
        r = $ex
        iszero(r) || @async @error($prefix * string(r))
        r
    end
end

macro check(ex::Expr) check(ex, false) end
macro check_iolock(ex::Expr) check(ex, true) end

# some libuv wrappers

const UV_READABLE = 1
const UV_WRITABLE = 2

function uv_poll_alloc()
    # allocate memory for: uv_poll_t struct + extra for curl_socket_t
    jl_malloc(Base._sizeof_uv_poll + sizeof(curl_socket_t))
end

function uv_poll_init(p::Ptr{Cvoid}, sock::curl_socket_t)
    @check_iolock ccall(:uv_poll_init, Cint,
        (Ptr{Cvoid}, Ptr{Cvoid}, curl_socket_t), Base.eventloop(), p, sock)
end

function uv_poll_start(p::Ptr{Cvoid}, events::Integer, cb::Ptr{Cvoid})
    @check_iolock ccall(:uv_poll_start, Cint,
        (Ptr{Cvoid}, Cint, Ptr{Cvoid}), p, events, cb)
end

function uv_poll_stop(p::Ptr{Cvoid})
    @check_iolock ccall(:uv_poll_stop, Cint, (Ptr{Cvoid},), p)
end

function uv_close(p::Ptr{Cvoid}, cb::Ptr{Cvoid})
    Base.iolock_begin()
    ccall(:uv_close, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), p, cb)
    Base.iolock_end()
end

function uv_timer_init(p::Ptr{Cvoid})
    @check_iolock ccall(:uv_timer_init, Cint,
        (Ptr{Cvoid}, Ptr{Cvoid}), Base.eventloop(), p)
end

function uv_timer_start(p::Ptr{Cvoid}, cb::Ptr{Cvoid}, t::Integer, r::Integer)
    @check_iolock ccall(:uv_timer_start, Cint,
        (Ptr{Cvoid}, Ptr{Cvoid}, UInt64, UInt64), p, cb, t, r)
end

function uv_timer_stop(p::Ptr{Cvoid})
    @check_iolock ccall(:uv_timer_stop, Cint, (Ptr{Cvoid},), p)
end

# additional libcurl methods

function curl_multi_socket_action(multi_handle, s, ev_bitmask)
    LibCURL.curl_multi_socket_action(multi_handle, s, ev_bitmask, Ref{Cint}())
end

# curl string list structure

struct curl_slist_t
    data::Ptr{Cchar}
    next::Ptr{curl_slist_t}
end

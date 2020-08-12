macro check(ex::Expr)
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
    quote
        r = $(esc(ex))
        iszero(r) || @async @error($prefix * string(r))
        nothing
    end
end

# some libuv wrappers

const UV_READABLE = 1
const UV_WRITABLE = 2

uv_poll_alloc() = ccall(:jl_malloc, Ptr{Cvoid}, (Csize_t,), Base._sizeof_uv_poll)

# TODO: was uv_poll_init_socket in example, but our libuv doesn't have that
function uv_poll_init(p::Ptr{Cvoid}, sock::curl_socket_t)
    @check ccall(:uv_poll_init, Cint,
        (Ptr{Cvoid}, Ptr{Cvoid}, curl_socket_t), Base.eventloop(), p, sock)
    # NOTE: if assertion fails need to store indirectly
    @assert sizeof(curl_socket_t) <= sizeof(Ptr{Cvoid})
    unsafe_store!(convert(Ptr{curl_socket_t}, p), sock)
    return nothing
end

function uv_poll_start(p::Ptr{Cvoid}, events::Integer, cb::Ptr{Cvoid})
    @check ccall(:uv_poll_start, Cint, (Ptr{Cvoid}, Cint, Ptr{Cvoid}), p, events, cb)
end

function uv_poll_stop(p::Ptr{Cvoid})
    @check ccall(:uv_poll_stop, Cint, (Ptr{Cvoid},), p)
end

function uv_close(p::Ptr{Cvoid}, cb::Ptr{Cvoid})
    ccall(:uv_close, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), p, cb)
end

function uv_timer_init(p::Ptr{Cvoid})
    @check ccall(:uv_timer_init, Cint, (Ptr{Cvoid}, Ptr{Cvoid}), Base.eventloop(), p)
end

function uv_timer_start(p::Ptr{Cvoid}, cb::Ptr{Cvoid}, t::Integer, r::Integer)
    @check ccall(:uv_timer_start, Cint,
        (Ptr{Cvoid}, Ptr{Cvoid}, UInt64, UInt64), p, cb, t, r)
end

function uv_timer_stop(p::Ptr{Cvoid})
    @check ccall(:uv_timer_stop, Cint, (Ptr{Cvoid},), p)
end

# additional libcurl methods

import LibCURL: curl_multi_socket_action

function curl_multi_socket_action(multi_handle, s, ev_bitmask)
    curl_multi_socket_action(multi_handle, s, ev_bitmask, Ref{Cint}())
end

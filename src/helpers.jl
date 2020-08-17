# basic C stuff

puts(s::Union{String,SubString{String}}) = ccall(:puts, Cint, (Ptr{Cchar},), s)

jl_malloc(n::Integer) = ccall(:jl_malloc, Ptr{Cvoid}, (Csize_t,), n)

# check if a function or C call failed

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

function uv_poll_alloc()
    # allocate memory for: uv_poll_t struct + extra for curl_socket_t
    jl_malloc(Base._sizeof_uv_poll + sizeof(curl_socket_t))
end

function uv_poll_init(p::Ptr{Cvoid}, sock::curl_socket_t)
    @check ccall(:uv_poll_init, Cint,
        (Ptr{Cvoid}, Ptr{Cvoid}, curl_socket_t), Base.eventloop(), p, sock)
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

# converting to & from curl string lists

struct curl_slist_t
    data::Ptr{Cchar}
    next::Ptr{curl_slist_t}
end

function to_curl_slist(strs)
    list_p = C_NULL
    for str in strs
        if str isa Pair
            key, val = str
            if val == nothing
                str = "$key:"
            else
                val = string(val)::String
                str = isempty(val) ? "$key;" : "$key: $val"
            end
        elseif !(str isa Union{String, SubString{String}})
            str = string(str)::String
        end
        list_p = curl_slist_append(list_p, str)
    end
    return convert(Ptr{curl_slist_t}, list_p)
end

function from_curl_slist(list_p::Ptr)
    strs = String[]
    while list_p != C_NULL
        list = unsafe_load(convert(Ptr{curl_slist_t}, list_p))
        push!(strs, unsafe_string(list.data))
        list_p = list.next
    end
    return strs
end

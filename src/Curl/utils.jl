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
    arg1 = ex.args[1] :: Symbol
    if arg1 == :ccall
        arg2 = ex.args[2]
        arg2 isa QuoteNode ||
            error("@check: ccallee must be a symbol")
        f = arg2.value :: Symbol
    else
        f = arg1
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
    if f in (:curl_easy_setopt, :curl_multi_setopt)
        unknown_option =
            f == :curl_easy_setopt  ? CURLE_UNKNOWN_OPTION :
            f == :curl_multi_setopt ? CURLM_UNKNOWN_OPTION : error()
        quote
            r = $ex
            if r == $unknown_option
                @async @error $prefix * string(r) * """\n
                You may be using an old system libcurl library that doesn't understand options that Julia uses. You can try the following Julia code to see which libcurl library you are using:

                    using Libdl
                    filter!(contains("curl"), dllist())

                If this indicates that Julia is not using the libcurl library that is shipped with Julia, then that is likely to be the problem. This either means:

                  1. You are using an unofficial Julia build which is configured to use a system libcurl library that is not recent enough; you may be able to fix this by upgrading the system libcurl. You should complain to your distro maintainers for allowing Julia to use a too-old libcurl version and consider using official Julia binaries instead.

                  2. You are overriding the library load path by setting `LD_LIBRARY_PATH`, in which case you are in advanced usage territory. You can try upgrading the system libcurl, unsetting `LD_LIBRARY_PATH`, or otherwise arranging for Julia to load a recent libcurl library.

                If neither of these is the case and Julia is picking up a too old libcurl, please file an issue with the `Downloads.jl` package.

                """
            elseif !iszero(r)
                @async @error $prefix * string(r)
            end
            r
        end
    else
        quote
            r = $ex
            iszero(r) || @async @error $prefix * string(r)
            r
        end
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

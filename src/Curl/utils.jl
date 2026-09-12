# Julia 1.14 gives every task a cancellation scope: cancelling it wakes the tasks parked
# under it with a `CancellationRequest`, and a `^C` in the REPL cancels the scope of the
# running evaluation. Two things follow for this package. The multi handle's plumbing, its
# socket watcher tasks and timers, is spawned from libcurl callbacks, which run on whatever
# task happened to call into libcurl, so it is given the multi as its owner rather than the
# scope of that caller. And the teardown of a request has to run even once the request's
# own scope has been cancelled. On older Julia none of this exists and all of it is a no-op.
@static if isdefined(Base, :CancellationTokenSource) && isdefined(Base, :CANCEL_TOKEN)
    const HAS_CANCELLATION = true
    cancel_source() = Base.CancellationTokenSource()
    cancel!(src::Base.CancellationTokenSource) = Base.cancel!(src)
    # run `f`, with the tasks and timers it creates owned by `src`
    owned(f, src::Base.CancellationTokenSource) =
        Base.ScopedValues.with(f, Base.CANCEL_TOKEN => Base.CancellationToken(src))
    # call `f(args...)` with cancellation of the enclosing scope masked
    shielded(f, args...) = Base.ScopedValues.with(() -> f(args...), Base.CANCEL_TOKEN => nothing)
    iscancellation(err) = err isa Base.CancellationRequest
else
    const HAS_CANCELLATION = false
    cancel_source() = nothing
    cancel!(::Nothing) = nothing
    owned(f, ::Nothing) = f()
    shielded(f, args...) = f(args...)
    iscancellation(err) = false
end

# basic C stuff

puts(s::Union{String,SubString{String}}) = ccall(:puts, Cint, (Ptr{Cchar},), s)

jl_malloc(n::Integer) = ccall(:jl_malloc, Ptr{Cvoid}, (Csize_t,), n)

# check if a call failed

macro check(ex::Expr)
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
    if f in (:curl_easy_setopt, :curl_multi_setopt)
        unknown_option =
            f == :curl_easy_setopt  ? CURLE_UNKNOWN_OPTION :
            f == :curl_multi_setopt ? CURLM_UNKNOWN_OPTION : error()
        quote
            r = $(esc(ex))
            if r == $unknown_option
                @async @error $prefix * string(r) * """\n
                You may be using an old system libcurl library that doesn't understand options that Julia uses. You can try the following Julia code to see which libcurl library you are using:

                    using Libdl
                    filter!(contains("curl"), dllist())

                If this indicates that Julia is not using the libcurl library that is shipped with Julia, then that is likely to be the problem. This either means:

                  1. You are using an unofficial Julia build which is configured to use a system libcurl library that is not recent enough; you may be able to fix this by upgrading the system libcurl. You should complain to your distro maintainers for allowing Julia to use a too-old libcurl version and consider using official Julia binaries instead.

                  2. You are overriding the library load path by setting `LD_LIBRARY_PATH`, in which case you are in advanced usage territory. You can try upgrading the system libcurl, unsetting `LD_LIBRARY_PATH`, or otherwise arranging for Julia to load a recent libcurl library.

                If neither of these is the case and Julia is picking up a too old libcurl, please file an issue with the `Downloads.jl` package.

                """ maxlog=1_000
            elseif !iszero(r)
                @async @error $prefix * string(r) maxlog=1_000
            end
            r
        end
    else
        quote
            r = $(esc(ex))
            iszero(r) || @async @error $prefix * string(r) maxlog=1_000
            r
        end
    end
end

# curl string list structure

struct curl_slist_t
    data::Ptr{Cchar}
    next::Ptr{curl_slist_t}
end

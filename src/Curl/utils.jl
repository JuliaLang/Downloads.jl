if !@isdefined(contains)
    contains(haystack, needle) = occursin(needle, haystack)
    export contains
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

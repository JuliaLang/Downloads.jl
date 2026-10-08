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
    # the error path is in non-inlined functions so that each call site does not
    # compile its own logging task; the call site is passed for the log location and
    # for `maxlog`, which counts per site
    file = String(__source__.file::Symbol)
    line = __source__.line
    if f in (:curl_easy_setopt, :curl_multi_setopt)
        unknown_option =
            f == :curl_easy_setopt  ? CURLE_UNKNOWN_OPTION :
            f == :curl_multi_setopt ? CURLM_UNKNOWN_OPTION : error()
        quote
            r = $(esc(ex))
            if r == $unknown_option
                log_unknown_option($prefix, r, $file, $line)
            elseif !iszero(r)
                log_check_error($prefix, r, $file, $line)
            end
            r
        end
    else
        quote
            r = $(esc(ex))
            iszero(r) || log_check_error($prefix, r, $file, $line)
            r
        end
    end
end

@noinline function log_check_error(prefix::String, r::Integer, file::String, line::Int)
    id = Symbol(file, ":", line)
    @async @error prefix * string(r) _file=file _line=line _id=id maxlog=1_000
    return
end

@noinline function log_unknown_option(prefix::String, r::Integer, file::String, line::Int)
    id = Symbol(file, ":", line)
    @async @error prefix * string(r) * """\n
    You may be using an old system libcurl library that doesn't understand options that Julia uses. You can try the following Julia code to see which libcurl library you are using:

        using Libdl
        filter!(contains("curl"), dllist())

    If this indicates that Julia is not using the libcurl library that is shipped with Julia, then that is likely to be the problem. This either means:

      1. You are using an unofficial Julia build which is configured to use a system libcurl library that is not recent enough; you may be able to fix this by upgrading the system libcurl. You should complain to your distro maintainers for allowing Julia to use a too-old libcurl version and consider using official Julia binaries instead.

      2. You are overriding the library load path by setting `LD_LIBRARY_PATH`, in which case you are in advanced usage territory. You can try upgrading the system libcurl, unsetting `LD_LIBRARY_PATH`, or otherwise arranging for Julia to load a recent libcurl library.

    If neither of these is the case and Julia is picking up a too old libcurl, please file an issue with the `Downloads.jl` package.

    """ _file=file _line=line _id=id maxlog=1_000
    return
end

# curl string list structure

struct curl_slist_t
    data::Ptr{Cchar}
    next::Ptr{curl_slist_t}
end

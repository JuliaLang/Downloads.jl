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
    quote
        r = $(esc(ex))
        iszero(r) || @async @error($prefix * string(r))
        r
    end
end

# curl string list structure

struct curl_slist_t
    data::Ptr{Cchar}
    next::Ptr{curl_slist_t}
end

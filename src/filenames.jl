## Getting file names from URLs and Responses

struct BadEncoding <: Exception end

function hex_digit(str::AbstractString, i::Int)::Tuple{UInt8,Int}
    if i ≤ ncodeunits(str)
        d, i = iterate(str, i)
        '0' ≤ d ≤ '9' && return d - '0', i
        'a' ≤ d ≤ 'f' && return d - 'a' + 10, i
        'A' ≤ d ≤ 'F' && return d - 'A' + 10, i
    end
    throw(BadEncoding())
end

function url_unescape(str::Union{String, SubString{String}})
    try return sprint(sizehint = ncodeunits(str)) do io
            i = 1
            while i ≤ ncodeunits(str)
                c, i = iterate(str, i)
                if c == '%'
                    hi, i = hex_digit(str, i)
                    lo, i = hex_digit(str, i)
                    x = hi*0x10 + lo
                    write(io, x)
                else
                    print(io, c)
                end
            end
        end
    catch err
        err isa BadEncoding && return
        rethrow()
    end
end

function url_filename(url::AbstractString)
    m = match(r"^[a-z][a-z+._-]*://[^#?]*/([^/#?]+)(?:[#?]|$)"i, url)
    m === nothing && return
    url_unescape(m[1])
end

let # build some complex regular expressions
    s = raw"\s*" # interpolating this is handy
    token = raw"[A-Za-z0-9!#$%&'*+-.\^_`|~]+"
    bare_value = raw"[^\s'\";][^;]*(?<!\s)"
    single_quoted = raw"'(?:[^'\\]|\\.)*'"
    double_quoted = raw"\"(?:[^\"\\]|\\.)*\""
    value = "(?:" *bare_value* "|" *single_quoted* "|" *double_quoted* ")"
    pair = "(" *token* ")$s=$s(" *value* ")"
    header_re = "^$s" *token* "$s(?:;$s" *pair* "$s)*;?$s\$"
    each_pair_re = "(?:^" *token* "|\\G)$s;$s" *pair
    global const content_disposition_re = Regex(header_re)
    global const content_disposition_each_re = Regex(each_pair_re)
end

function get_filename(response::Response)
    # look for content disposition header
    filename = filename⁺ = nothing
    for (h_key, h_val) in response.headers
        h_key == "content-disposition" &&
            contains(h_val, content_disposition_re) || continue
        for m in eachmatch(content_disposition_each_re, h_val)
            a_key = lowercase(m.captures[1])
            a_val = m.captures[2]
            a_val === nothing && continue
            if a_key == "filename"
                if a_val[1] in ('"', '\'') && a_val[1] == a_val[end]
                    # quoted value
                    filename = sprint(sizehint=ncodeunits(a_val)-2) do io
                        i = nextind(a_val, 1)
                        while i < ncodeunits(a_val)
                            c, i = iterate(a_val, i)
                            if c == '\\'
                                c, i = iterate(a_val, i)
                            end
                            write(io, c)
                        end
                    end
                else # unquoted value
                    filename = a_val
                end
            elseif a_key == "filename*"
                m = match(r"^([\w-]+)'\w*'(.*)$", a_val)
                m === nothing && continue
                encoding = lowercase(m.captures[1])
                encoding in ("utf-8", "iso-8859-1") || continue
                encoded = m.captures[2]
                try filename⁺ = sprint() do io
                        i = 1
                        while i ≤ ncodeunits(encoded)
                            c, i = iterate(encoded, i)
                            if c == '%'
                                hi, i = hex_digit(encoded, i)
                                lo, i = hex_digit(encoded, i)
                                x = hi*0x10 + lo
                                if encoding == "utf-8"
                                    write(io, x)
                                else
                                    write(io, Char(x))
                                end
                            else
                                write(io, c)
                            end
                        end
                    end
                catch err
                    err isa BadEncoding || rethrow()
                end
            end
        end
    end
    filename⁺ !== nothing && return filename⁺
    filename !== nothing && return filename
    # no usable content disposition header
    # extract from URL after redirects
    return url_filename(response.url)
end

# Special names on Windows: CON PRN AUX NUL COM1-9 LPT1-9
# we spell out uppercase/lowercase because of locales
# these are dangerous with or without an extension
const WIN_SPECIAL_NAMES = r"^(
    [Cc][Oo][Nn] |
    [Pp][Rr][Nn] |
    [Aa][Uu][Xx] |
    [Nn][Uu][Ll] |
    [Cc][Oo][Mm][1-9] |
    [Ll][Pp][Tt][1-9]
)(\.|$)"x

function is_safe_filename(name::AbstractString)
    isvalid(name) || return false
    '/' in name && return false
    name in ("", ".", "..") && return false
    any(iscntrl, name) && return false
    if Sys.iswindows()
        name[end] ∈ ". " && return false
        any(in("\"*:<>?\\|"), name) && return false
        contains(name, WIN_SPECIAL_NAMES) && return false
    end
    return true
end

is_safe_filename(::Nothing) = false

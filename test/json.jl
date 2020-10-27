module JSON

using Base: peek # not exported until Julia 1.5

function parse(str::AbstractString)
    try
        tokens = Iterators.Stateful(tokenize(str))
        value = parse_value!(tokens)
        isempty(tokens) || error()
        return value
    catch
        error("invalid JSON: $str")
    end
end

function parse_value!(tokens::Iterators.Stateful)
    token = peek(tokens)
    token == '[' ? parse_array!(tokens) :
    token == '{' ? parse_dict!(tokens) :
    token isa Char ? error() : popfirst!(tokens)
end

function pop_comma!(tokens::Iterators.Stateful)
    peek(tokens) == ',' || return false
    popfirst!(tokens)
    return true
end

function parse_array!(tokens::Iterators.Stateful)
    array = []
    popfirst!(tokens) == '[' || error()
    while peek(tokens) != ']'
        value = parse_value!(tokens)
        push!(array, value)
        pop_comma!(tokens) || break
    end
    popfirst!(tokens) == ']' || error()
    return array
end

function parse_dict!(tokens::Iterators.Stateful)
    dict = Dict{String,Any}()
    popfirst!(tokens) == '{' || error()
    while peek(tokens) != '}'
        key = popfirst!(tokens)
        key isa String || error()
        popfirst!(tokens) == ':' || error()
        value = parse_value!(tokens)
        dict[key] = value
        pop_comma!(tokens) || break
    end
    popfirst!(tokens) == '}' || error()
    return dict
end

function tokenize(str::AbstractString)
    tokens = []
    chars = Iterators.Stateful(str)
    isspecial(c::Char) = isspace(c) || c in "{}[],:\""
    for c in chars
        if isspace(c)
            continue
        elseif c == '"'
            s = sprint() do io
                for c in chars
                    if c == '"'
                        break
                    elseif c == '\\'
                        c = popfirst!(chars)
                        if c == 'u'
                            s = popfirst!(chars) * popfirst!(chars) *
                                popfirst!(chars) * popfirst!(chars)
                            print(io, Char(parse(Int, s, base=16)))
                        else
                            c = c == 'b' ? '\b' :
                                c == 'f' ? '\f' :
                                c == 'n' ? '\n' :
                                c == 'r' ? '\r' :
                                c == 't' ? '\t' :
                                c == 'v' ? '\v' :
                                c in "\\\"'" ? c : error()
                            print(io, c)
                        end
                    else
                        print(io, c)
                    end
                end
            end
            push!(tokens, s)
        elseif isspecial(c)
            push!(tokens, c)
        else
            word = sprint() do io
                print(io, c)
                while !isempty(chars) && !isspecial(peek(chars))
                    print(io, popfirst!(chars))
                end
            end
            token = word == "true"  ? true :
                    word == "false" ? false :
                    word == "null"  ? nothing :
                    word[1] in "0123456789.+-" ? parse(Float64, word) : error()
            push!(tokens, token)
        end
    end
    return tokens
end

end # module

using Test
using Downloads
using Downloads.Curl

include("json.jl")

if VERSION < v"1.5"
    contains(haystack, needle) = occursin(needle, haystack)
end

function download_body(url::AbstractString, headers = Union{}[])
    sprint() do io
        Downloads.download(url, io, headers = headers)
    end
end

function download_json(url::AbstractString, headers = Union{}[])
    json.parse(download_body(url, headers))
end

function request_body(multi::Multi, url::AbstractString, headers = Union{}[])
    resp = nothing
    body = sprint() do io
        req = Request(io, url, headers)
        resp = Downloads.request(req, multi)
    end
    return resp, body
end

function request_json(multi::Multi, url::AbstractString, headers = Union{}[])
    resp, body = request_body(multi, url, headers)
    return resp, json.parse(body)
end

function header(hdrs::Dict, hdr::AbstractString)
    hdr = lowercase(hdr)
    for (key, values) in hdrs
        lowercase(key) == hdr || continue
        values isa Vector || error("header value should be a vector")
        length(values) == 1 || error("header value should have length 1")
        return values[1]
    end
    error("header not found")
end

function test_response_string(response::AbstractString, status::Integer)
    m = match(r"^HTTP/\d+(?:\.\d+)?\s+(\d+)\b", response)
    @test m !== nothing
    @test parse(Int, m.captures[1]) == status
end

macro exception(ex)
    quote
        try $(esc(ex))
        catch err
            err
        end
    end
end

# URL escape & unescape

function is_url_safe_byte(byte::UInt8)
    0x2d ≤ byte ≤ 0x2e ||
    0x30 ≤ byte ≤ 0x39 ||
    0x41 ≤ byte ≤ 0x5a ||
    0x61 ≤ byte ≤ 0x7a ||
    byte == 0x5f ||
    byte == 0x7e
end

function url_escape(str::Union{String, SubString{String}})
    sprint(sizehint = ncodeunits(str)) do io
        for byte in codeunits(str)
            if is_url_safe_byte(byte)
                write(io, byte)
            else
                write(io, '%', string(byte, base=16, pad=2))
            end
        end
    end
end
url_escape(str::AbstractString) = url_escape(String(str))

const multi = Multi()
const server = "https://httpbingo.julialang.org"

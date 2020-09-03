# this is needed for testing Downloader as a stdlib
# in normal testing it has no effect
if true
    import Pkg
    temp = mktempdir()
    Pkg.activate(temp)
    Pkg.add("JSON")
    insert!(LOAD_PATH, 2, temp)
    Pkg.activate()
end

using Test, JSON
using Downloader
using Downloader.Curl

function download_body(multi::Multi, url::AbstractString, headers = Union{}[])
    sprint() do io
        Downloader.download(multi, url, io, headers)
    end
end

function download_json(multi::Multi, url::AbstractString, headers = Union{}[])
    JSON.parse(download_body(multi, url, headers))
end

function get_body(multi::Multi, url::AbstractString, headers = Union{}[])
    resp = nothing
    body = sprint() do io
        req = Request(io, url, headers)
        resp = Downloader.get(req, multi)
    end
    return resp, body
end

function get_json(multi::Multi, url::AbstractString, headers = Union{}[])
    resp, body = get_body(multi, url, headers)
    return resp, JSON.parse(body)
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
const server = "https://httpbingo.org"

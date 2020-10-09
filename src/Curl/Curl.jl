module Curl

export
    Easy,
        set_url,
        add_header,
        enable_progress,
        get_effective_url,
        get_response_code,
        get_response_headers,
    Multi,
        add_handle,
        remove_handle

using LibCURL
using LibCURL: curl_off_t
# not exported: https://github.com/JuliaWeb/LibCURL.jl/issues/87

include("utils.jl")

function __init__()
    @check curl_global_init(CURL_GLOBAL_ALL)
end

const CURL_VERSION = unsafe_string(curl_version())
const USER_AGENT = "$CURL_VERSION julia/$VERSION"

include("Easy.jl")
include("Multi.jl")

function add_handle(multi::Multi, easy::Easy)
    @check curl_multi_add_handle(multi.handle, easy.handle)
    multi.count += 1
end

function remove_handle(multi::Multi, easy::Easy)
    @check curl_multi_remove_handle(multi.handle, easy.handle)
    multi.count -= 1
end

end # module

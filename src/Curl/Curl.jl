module Curl

export
    Easy,
        set_url,
        add_header,
        get_effective_url,
        get_response_code,
        get_response_headers,
    Multi,
        add_handle,
        remove_handle

using LibCURL

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
end

function remove_handle(multi::Multi, easy::Easy)
    @check curl_multi_remove_handle(multi.handle, easy.handle)
end

end # module

module Curl

export Multi, Easy, add_handle, remove_handle, set_url, set_headers

using LibCURL

include("helpers.jl")

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

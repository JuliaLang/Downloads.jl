module Curl

export
    with_handle,
    Easy,
        set_url,
        set_method,
        set_verbose,
        set_body,
        set_upload_size,
        set_seeker,
        set_ca_roots_path,
        add_headers,
        enable_upload,
        enable_progress,
        upload_data,
        get_effective_url,
        get_response_status,
        get_response_info,
        get_curl_errstr,
    Multi,
        add_handle,
        remove_handle

using LibCURL
using LibCURL: curl_off_t
# not exported: https://github.com/JuliaWeb/LibCURL.jl/issues/87

using NetworkOptions
using Base: preserve_handle, unpreserve_handle

include("utils.jl")

function __init__()
    @check curl_global_init(CURL_GLOBAL_ALL)
end

const CURL_VERSION_INFO = unsafe_load(curl_version_info(CURLVERSION_NOW))
const SSL_VERSION = unsafe_string(CURL_VERSION_INFO.ssl_version)
const SYSTEM_SSL =
    Sys.isapple() && startswith(SSL_VERSION, "SecureTranspart")
    Sys.iswindows() && startswith(SSL_VERSION, "Schannel")

const CURL_VERSION = unsafe_string(curl_version())
const USER_AGENT = "$CURL_VERSION julia/$VERSION"

include("Easy.jl")
include("Multi.jl")

function with_handle(f, handle::Union{Multi, Easy})
    try f(handle)
    finally
        Curl.done!(handle)
    end
end

end # module

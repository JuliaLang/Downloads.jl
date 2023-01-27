module Curl

export
    with_handle,
    Easy,
        set_url,
        set_method,
        set_verbose,
        set_debug,
        set_body,
        set_upload_size,
        set_seeker,
        set_ca_roots_path,
        set_timeout,
        add_headers,
        enable_upload,
        enable_progress,
        upload_data,
        get_protocol,
        get_effective_url,
        get_response_status,
        get_response_info,
        get_curl_errstr,
        status_ok,
    Multi,
        add_handle,
        remove_handle

using LibCURL
using LibCURL: curl_off_t, libcurl
# not exported: https://github.com/JuliaWeb/LibCURL.jl/issues/87

# constants that LibCURL should have but doesn't
const CURLE_PEER_FAILED_VERIFICATION = 60
const CURLSSLOPT_REVOKE_BEST_EFFORT = 1 << 3
const CURLOPT_PREREQFUNCTION = 20000 + 312
const CURLOPT_PREREQDATA = 10000 + 313

# these are incorrectly defined on Windows by LibCURL:
if Sys.iswindows()
    const curl_socket_t = Base.OS_HANDLE
    const CURL_SOCKET_TIMEOUT = Base.INVALID_OS_HANDLE
else
    const curl_socket_t = Cint
    const CURL_SOCKET_TIMEOUT = -1
end

# definitions affected by incorrect curl_socket_t (copied verbatim):
function curl_multi_socket_action(multi_handle, s, ev_bitmask, running_handles)
    ccall((:curl_multi_socket_action, libcurl), CURLMcode, (Ptr{CURLM}, curl_socket_t, Cint, Ptr{Cint}), multi_handle, s, ev_bitmask, running_handles)
end
function curl_multi_assign(multi_handle, sockfd, sockp)
    ccall((:curl_multi_assign, libcurl), CURLMcode, (Ptr{CURLM}, curl_socket_t, Ptr{Cvoid}), multi_handle, sockfd, sockp)
end

# additional curl_multi_socket_action method
function curl_multi_socket_action(multi_handle, s, ev_bitmask)
    curl_multi_socket_action(multi_handle, s, ev_bitmask, Ref{Cint}())
end

using FileWatching
using NetworkOptions
using Base: OS_HANDLE, preserve_handle, unpreserve_handle

include("utils.jl")

function __init__()
    @check curl_global_init(CURL_GLOBAL_ALL)
end

const CURL_VERSION_INFO = unsafe_load(curl_version_info(CURLVERSION_NOW))
if CURL_VERSION_INFO.ssl_version == Base.C_NULL
    const SSL_VERSION = ""
else
    const SSL_VERSION = unsafe_string(CURL_VERSION_INFO.ssl_version)::String
end
const SYSTEM_SSL =
    Sys.isapple() && startswith(SSL_VERSION, "SecureTransport") ||
    Sys.iswindows() && startswith(SSL_VERSION, "Schannel")

const CURL_VERSION_STR = unsafe_string(curl_version())
let m = match(r"^libcurl/(\d+\.\d+\.\d+)\b", CURL_VERSION_STR)
    m !== nothing || error("unexpected CURL_VERSION_STR value")
    curl = m.captures[1]
    julia = "$(VERSION.major).$(VERSION.minor)"
    global const CURL_VERSION = VersionNumber(curl)
    global const USER_AGENT = "curl/$curl julia/$julia"
end

include("Easy.jl")
include("Multi.jl")

function with_handle(f, handle::Union{Multi, Easy})
    try f(handle)
    finally
        Curl.done!(handle)
    end
end

"""
    setopt(easy::Easy, option::Integer, value)

Sets options on libcurl's "easy" interface. `option` corresponds to libcurl options on https://curl.se/libcurl/c/curl_easy_setopt.html
"""
setopt(easy::Easy, option::Integer, value) =
    @check curl_easy_setopt(easy.handle, option, value)

"""
    setopt(multi::Multi, option::Integer, value)

Sets options on libcurl's "multi" interface. `option` corresponds to libcurl options on https://curl.se/libcurl/c/curl_multi_setopt.html
"""
setopt(multi::Multi, option::Integer, value) =
    @check curl_multi_setopt(multi.handle, option, value)

end # module

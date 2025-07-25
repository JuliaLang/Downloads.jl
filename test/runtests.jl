include("setup.jl")

@testset "Downloads.jl" begin
    @testset "libcurl configuration" begin
        julia = "$(VERSION.major).$(VERSION.minor)"
        @test Curl.USER_AGENT == "curl/$(Curl.CURL_VERSION) julia/$julia"
        if Curl.CURL_VERSION < v"8.15"
            @test Curl.SYSTEM_SSL == Sys.iswindows() | Sys.isapple()
        else
            # Starting with curl 8.15 we use OpenSSL on Apple platforms
            @test Curl.SYSTEM_SSL == Sys.iswindows()
        end
    end

    @testset "API coverage" begin
        value = "Julia is great!"
        base64 = "SnVsaWEgaXMgZ3JlYXQh"
        url = "$server/base64/$base64"
        headers = ["Foo" => "Bar"]
        # test with one argument
        path = download(url)
        @test isfile(path)
        @test value == read(path, String)
        rm(path)
        # with headers
        path = download(url; headers)
        @test isfile(path)
        @test value == read(path, String)
        rm(path)
        # test with two arguments
        arg_writers() do path, output
            @arg_test output begin
                @test output == download(url, output)
            end
            @test isfile(path)
            @test value == read(path, String)
            rm(path)
            # with headers
            @arg_test output begin
                @test output == download(url, output; headers)
            end
            @test isfile(path)
            @test value == read(path, String)
            rm(path)
        end

        # not an API test, but a convenient place to test this
        @testset "follow redirects" begin
            redirect = "$server/redirect-to?url=$(url_escape(url))"
            path = download(redirect)
            @test isfile(path)
            @test value == read(path, String)
            rm(path)
        end
    end

    @testset "get request" begin
        url = "$server/get"
        json = download_json(url)
        @test json["url"] == url
        resp = request(url)
        @test resp isa Response
        @test resp.proto == "https"
        @test resp.status == 200
    end

    # https://github.com/JuliaLang/Downloads.jl/issues/131
    @testset "head request" begin
        url = server * "/image/jpeg"
        output = IOBuffer()
        resp = request(url; method="HEAD", output)
        @test resp isa Response
        @test resp.proto == "https"
        @test resp.status == 200
        @test isempty(take!(output)) # no output from a `HEAD`
        len = parse(Int, Dict(resp.headers)["content-length"])

        # when we make a `GET` instead of a `HEAD`, we get a body with the content-length
        # returned from the `HEAD` request.
        resp = request(url; method="GET", output)
        bytes = take!(output)
        @test length(bytes) == len
    end

    @testset "put request" begin
        url = "$server/put"
        data = "Hello, world!"
        resp, json = request_json(url, input=IOBuffer(data))
        @test json["url"] == url
        @test json["data"] == data
    end

    @testset "post request" begin
        url = "$server/post"
        data = "Hello, world!"
        resp, json = request_json(url, input=IOBuffer(data), method="POST")
        @test json["url"] == url
        @test json["data"] == data
    end

    @testset "put from file" begin
        url = "$server/put"
        file = tempname()
        write(file, "Hello, world!")
        resp, json = request_json(url, input=file)
        @test json["url"] == url
        @test json["data"] == read(file, String)
        rm(file)
    end

    @testset "put from io" begin
        url = "$server/put"
        file = tempname()
        write(file, "Hello, world!")
        len = filesize(file)
        for headers in [Pair{String,String}[], ["Content-Length" => "$len"]]
            open(file) do io
                events = Pair{String,String}[]
                debug(type, msg) = push!(events, type => msg)
                resp, json = request_json(url; input=io, debug, headers)
                @test json["url"] == url
                @test json["data"] == read(file, String)
                header_out(hdr::String) = any(events) do (type, msg)
                    type == "HEADER OUT" && hdr in map(lowercase, split(msg, "\r\n"))
                end
                chunked = header_out("transfer-encoding: chunked")
                content_length = header_out("content-length: $len")
                if isempty(headers)
                    @test chunked && !content_length
                else
                    @test !chunked && content_length
                end
            end
        end
        rm(file)
    end

    @testset "redirected get" begin
        url = "$server/get"
        redirect = "$server/redirect-to?url=$(url_escape(url))"
        json = download_json(url)
        @test json["url"] == url
    end

    @testset "redirected put" begin
        url = "$server/put"
        redirect = "$server/redirect-to?url=$(url_escape(url))"
        data = "Hello, world!"
        resp, json = request_json(redirect, input=IOBuffer(data))
        @test json["url"] == url
        @test json["data"] == data
    end

    @testset "redirected post" begin
        url = "$server/post"
        redirect = "$server/redirect-to?url=$(url_escape(url))"
        data = "Hello, world!"
        resp, json = request_json(redirect, input=IOBuffer(data), method="POST")
        @test json["url"] == url
        @test json["data"] == data
    end

    @testset "redirected put from file" begin
        url = "$server/put"
        redirect = "$server/redirect-to?url=$(url_escape(url))"
        file = tempname()
        write(file, "Hello, world!")
        resp, json = request_json(redirect, input=file)
        @test json["url"] == url
        @test json["data"] == read(file, String)
    end

    @testset "headers" begin
        url = "$server/headers"

        @testset "set headers" begin
            headers = ["Foo" => "123", "Header" => "VaLuE", "Empty" => ""]
            json = download_json(url; headers)
            for (key, value) in headers
                @test header(json["headers"], key) == value
            end
            @test header(json["headers"], "Accept") == "*/*"
            @test header(json["headers"], "User-Agent") == Curl.USER_AGENT
        end

        @testset "override default header" begin
            headers = [
                "Accept"     => "application/tar"
                "User-Agent" => "MyUserAgent/1.0"
            ]
            json = download_json(url; headers)
            @test header(json["headers"], "Accept") == "application/tar"
            @test header(json["headers"], "User-Agent") == "MyUserAgent/1.0"
        end

        @testset "override default header with empty value" begin
            headers = [
                "Accept"     => ""
                "User-Agent" => ""
            ]
            json = download_json(url; headers)
            @test header(json["headers"], "Accept") == ""
            @test header(json["headers"], "User-Agent") == ""
        end

        @testset "delete default header" begin
            headers = [
                "Accept"     => nothing
                "User-Agent" => nothing
            ]
            json = download_json(url; headers)
            @test !("Accept" in keys(json["headers"]))
            @test !("User-Agent" in keys(json["headers"]))
        end

        @testset "HTTP/2 user agent bug" begin
            json = download_json(url)
            @test header(json["headers"], "User-Agent") == Curl.USER_AGENT
            @sync for _ = 1:2
                @async begin
                    json = download_json(url)
                    @test header(json["headers"], "User-Agent") == Curl.USER_AGENT
                end
            end
        end
    end

    @testset "download file names" begin
        @testset "url_filename helper" begin
            for url in urls_with_filename()
                @test nothing === Downloads.url_filename(url)
            end
            for name in file_names,
                url in urls_with_filename(name)
                if Sys.iswindows() && '"' in name
                    @test nothing === Downloads.url_filename(url)
                else
                    @test name === Downloads.url_filename(url)
                end
            end
            # URLs that we shouldn't get a file name from
            for url in [
                "",
                "abc",
                "abc.txt",
                "abc:def",
                "file:/",
                "file://",
                "file:///",
                "$server/anything/%",
                "$server/anything/%.txt",
                "$server/anything/%0.txt",
            ]
                @test nothing === Downloads.url_filename(url)
            end
        end
        # set a more unique default file name
        default = Downloads.DEFAULT_FILENAME
        @testset "from URL" begin
            for url in rand(urls_with_filename(), 10)
                @test default == splitdir(download(url))[2]
                url′ = "$server/redirect-to?url="*url_escape(url)
                # would be reasonable for this to be `default` too but
                # currently we use the name from the original URL
                @test Downloads.url_filename(url′) ==
                    splitdir(download(url′))[2]
            end
            for name in file_names
                Sys.iswindows() && '"' in name && continue
                for url in rand(urls_with_filename(name), 3)
                    @test name == splitdir(download(url))[2]
                    url′ = "$server/redirect-to?url="*url_escape(url)
                    @test name == splitdir(download(url′))[2]
                end
            end
        end
        @testset "unsafe names in URLs" begin
            bad_names = [
                url_escape(".")
                url_escape("..")
                url_escape("\a")
                "%ff"
                "%ff.txt"
            ]
            if Sys.iswindows()
                push!(bad_names, url_escape("file."))
                push!(bad_names, url_escape("file "))
                push!(bad_names, url_escape("file:txt"))
                push!(bad_names, url_escape("CON"))
                push!(bad_names, url_escape("LPT1.txt"))
            end
            for name in bad_names
                url = "$server/anything/$name"
                @test default == splitdir(download(url))[2]
            end
        end
        @testset "from content disposition" begin
            for name in file_names
                Sys.iswindows() && '"' in name && continue
                url = content_disposition_url(:utf8 => name)
                @test name == splitdir(download(url))[2]
                isascii(name) || continue
                url = content_disposition_url(:ascii => name)
                @test name == splitdir(download(url))[2]
                url = content_disposition_url(:ascii_1q => name)
                @test name == splitdir(download(url))[2]
                url = content_disposition_url(:ascii_2q => name)
                @test name == splitdir(download(url))[2]
            end
            let name = "ÿ.txt"
                url = content_disposition_url(:latin1 => name)
                @test name == splitdir(download(url))[2]
            end
            let name = "y.txt", name⁺ = "ÿ.txt"
                url = content_disposition_url(:ascii => name, :utf8 => name⁺)
                @test name⁺ == splitdir(download(url))[2]
                url = content_disposition_url(:ascii => name, :latin1 => name⁺)
                @test name⁺ == splitdir(download(url))[2]
                url = content_disposition_url(:utf8 => name⁺, :ascii => name)
                @test name⁺ == splitdir(download(url))[2]
                url = content_disposition_url(:latin1 => name⁺, :ascii => name)
                @test name⁺ == splitdir(download(url))[2]
                url = content_disposition_url(:latin1 => name, :utf8 => name⁺)
                @test name⁺ == splitdir(download(url))[2]
                url = content_disposition_url(:utf8 => name, :latin1 => name⁺)
                @test name⁺ == splitdir(download(url))[2]
            end
            let name = "valid.txt", name⁺ = "invalid\0.txt"
                url = content_disposition_url(:ascii => name, :utf8 => name⁺)
                @test name == splitdir(download(url))[2]
            end
        end
        @testset "invalid content disposition" begin
            # invalid content disposition header syntax
            values = [
                "\a\b"
                "inline"
                "attachment"
                "attachment; filename"
                "attachment; filename='"
                "attachment; filename=\""
                "attachment; filename='unclosed"
                "attachment; filename=\"unclosed"
                "attachment; filename*=name.txt"
                "attachment; filename*='name.txt'"
                "attachment; filename*=\"name.txt\""
                "attachment; filename*=utf-8''%"
                "attachment; filename*=utf-8''%.txt"
            ]
            bad_names = [
                ""
                "."
                ".."
                "foo/bar"
                "foo\0"
                "\a"
                "ding!\v"
            ]
            if Sys.iswindows()
                push!(bad_names, "file.")
                push!(bad_names, "file ")
                push!(bad_names, "file:txt")
                push!(bad_names, "CON")
                push!(bad_names, "LPT1.txt")
            end
            for name in bad_names
                push!(values, "attachment; filename*=utf-8''$(url_escape(name))")
                '\0' in name && continue
                push!(values, "attachment; filename=\"$name\"")
            end
            for value in values
                url = "$server/response-headers?content-disposition="*
                    url_escape(value)
                @test "response-headers" === splitdir(download(url))[2]
            end
        end
    end

    @testset "debug callback" begin
        url = "$server/get"
        events = Pair{String,String}[]
        resp = request(url, debug = (type, msg) -> push!(events, type => msg))
        @test resp isa Response && resp.status == 200
        @test any(events) do (type, msg)
            type == "TEXT" && startswith(msg, r"(Connected to |Connection.* left intact)")
        end
        @test any(events) do (type, msg)
            type == "HEADER OUT" && contains(msg, r"^HEAD /get HTTP/[\d\.+]+\s$"m)
        end
        @test any(events) do (type, msg)
            type == "HEADER IN" && contains(msg, r"^HTTP/[\d\.]+ 200 OK\s*$")
        end
    end

    @testset "session support" begin
        downloader = Downloader()

        # This url will redirect to /cookies, which echoes the set cookies as json
        set_cookie_url = "$server/cookies/set?k1=v1&k2=v2"
        cookies = download_json(set_cookie_url; downloader)
        @test get(cookies, "k1", "") == "v1"
        @test get(cookies, "k2", "") == "v2"

        # As the handle is destroyed, subsequent requests have no cookies
        cookie_url = "$server/cookies"
        cookies = download_json(cookie_url; downloader)
        @test isempty(cookies)
    end

    @testset "default_downloader!" begin
        original = Downloads.DOWNLOADER[]
        try
            tripped = false
            url = "$server/get"

            downloader = Downloader()
            downloader.easy_hook = (easy, info) -> tripped = true

            # set default
            default_downloader!(downloader)
            _ = download_body(url)
            @test tripped

            #reset tripwire
            tripped = false

            # reset default
            default_downloader!()
            _ = download_body(url)
            @test !tripped
        finally
            Downloads.DOWNLOADER[] = original
        end
    end

    @testset "netrc support" begin
        user = "gVvkQiHN62"
        passwd = "dlctfSMTno8n"
        auth_url = "$server/basic-auth/$user/$passwd"
        resp = request(auth_url)
        @test resp isa Response
        @test resp.status == 401  # no succesful authentication

        # Setup .netrc
        hostname = match(r"^\w+://([^/]+)"i, server).captures[1]
        netrc = tempname()
        open(netrc, "w") do io
            write(io, "machine $hostname login $user password $passwd\n")
        end

        # Setup config to point to custom .netrc (normally in ~/.netrc)
        downloader = Downloads.Downloader()
        downloader.easy_hook = (easy, info) ->
            Curl.setopt(easy, Curl.CURLOPT_NETRC_FILE, netrc)

        resp = request(auth_url; downloader, throw=false)
        @test resp isa Response
        @test resp.status == 200  # succesful authentication

        # Cleanup
        rm(netrc)
    end

    @testset "file protocol" begin
        @testset "success" begin
            path = tempname()
            data = rand(UInt8, 256)
            write(path, data)
            temp = download("file://$path")
            @test data == read(temp)
            output = IOBuffer()
            resp = request("file://$path"; output)
            @test resp isa Response
            @test resp.proto == "file"
            @test resp.status == 0
            @test take!(output) == data
            rm(path)
        end
        @testset "failure" begin
            path = tempname()
            @test_throws RequestError download("file://$path")
            @test_throws RequestError request("file://$path")
            output = IOBuffer()
            resp = request("file://$path"; output, throw = false)
            @test resp isa RequestError
        end
    end

    @testset "errors" begin
        @test_throws ArgumentError download("ba\0d")
        @test_throws ArgumentError download("good", "ba\0d")

        err = @exception download("xyz://domain.invalid")
        @test err isa RequestError
        @test err.code != 0
        @test startswith(err.message, "Protocol \"xyz\" not supported")
        @test err.response.proto === nothing

        err = @exception request("xyz://domain.invalid", input = IOBuffer("Hi"))
        @test err isa RequestError
        @test err.code != 0
        @test startswith(err.message, "Protocol \"xyz\" not supported")
        @test err.response.proto === nothing

        err = @exception download("https://domain.invalid")
        @test err isa RequestError
        @test err.code != 0
        @test startswith(err.message, "Could not resolve host")
        if Curl.CURL_VERSION < v"8.10"
            @test err.response.proto === nothing
        else
            @test err.response.proto == "https"
        end

        err = @exception request("https://domain.invalid", input = IOBuffer("Hi"))
        @test err isa RequestError
        @test err.code != 0
        @test startswith(err.message, "Could not resolve host")
        if Curl.CURL_VERSION < v"8.10"
            @test err.response.proto === nothing
        else
            @test err.response.proto == "https"
        end

        err = @exception download("$server/status/404")
        @test err isa RequestError
        @test err.code == 0 && isempty(err.message)
        @test err.response.status == 404
        @test contains(err.response.message, r"^HTTP/\d+(?:\.\d+)?\s+404\b")
        @test err.response.proto === "https"

        resp = request("$server/get", input = IOBuffer("Hi"))
        @test resp isa Response
        @test resp.status == 405
        @test contains(resp.message, r"^HTTP/\d+(?:\.\d+)?\s+405\b")
        @test err.response.proto === "https"

        path = tempname()
        @test_throws RequestError download("$server/status/404", path)
        @test !ispath(path)
    end

    @testset "concurrent requests" begin
        if Sys.iswindows()
            # Known issue https://github.com/JuliaLang/Downloads.jl/issues/227
            # These test should be fixed on Windows and then reenabled.
            @test_skip "concurrent requests flakey on Windows"
        else
            mine = Downloader()
            for downloader in (nothing, mine)
                have_lsof = Sys.which("lsof") !== nothing
                count_tcp() = Base.count(x->contains("TCP",x), split(read(`lsof -p $(getpid())`, String), '\n'))
                if have_lsof
                    n_tcp = count_tcp()
                end
                delay = 2
                count = 100
                url = "$server/delay/$delay"
                t = @elapsed @sync for id = 1:count
                    @async begin
                        json = download_json("$url?id=$id"; downloader)
                        @test get(json["args"], "id", nothing) == ["$id"]
                    end
                end
                @test t < 0.9*count*delay
                if have_lsof
                    @test n_tcp == count_tcp()
                end
            end
        end
    end

    @testset "request API" begin
        @testset "basic request usage" begin
            for status in [200, 400, 404]
                url = "$server/status/$status"
                resp, body = request_body(url)
                @test resp.url == url
                @test resp.status == status
                test_response_string(resp.message, status)
                @test all(hdr isa Pair{String,String} for hdr in resp.headers)
                headers = Dict(resp.headers)
                @test "content-length" in keys(headers)
            end
        end

        @testset "custom headers" begin
            url = "$server/response-headers?FooBar=VaLuE"
            resp, body = request_body(url)
            @test resp.url == url
            @test resp.status == 200
            test_response_string(resp.message, 200)
            headers = Dict(resp.headers)
            @test headers["foobar"] == "VaLuE"
        end

        @testset "url for redirect" begin
            url = "$server/get"
            redirect = "$server/redirect-to?url=$(url_escape(url))"
            resp, json = request_json(redirect)
            @test resp.url == url
            @test resp.status == 200
            test_response_string(resp.message, 200)
            @test json["url"] == url
        end

        @testset "timeouts" begin
            url = "$server/delay/2"
            @testset "download" begin
                @test_throws ArgumentError download(url, devnull, timeout = -1)
                @test_throws ArgumentError download(url, devnull, timeout = 0)
                @test_throws RequestError download(url, devnull, timeout = 1)
                @test_throws RequestError download(url, devnull, timeout = 0.5)
                @test download(url, devnull, timeout = 100) == devnull
                @test download(url, devnull, timeout = Inf) == devnull
            end
            @testset "request(throw = true)" begin
                @test_throws ArgumentError request(url, timeout = -1)
                @test_throws ArgumentError request(url, timeout = 0)
                @test_throws RequestError request(url, timeout = 1)
                @test_throws RequestError request(url, timeout = 0.5)
                @test request(url, timeout = 100) isa Response
                @test request(url, timeout = Inf) isa Response
            end
            @testset "request(throw = false)" begin
                @test request(url, throw = false, timeout = 1) isa RequestError
                @test request(url, throw = false, timeout = 0.5) isa RequestError
                @test request(url, throw = false, timeout = 100) isa Response
                @test request(url, throw = false, timeout = Inf) isa Response
            end
        end

        @testset "interrupt" begin
            url = "$server/delay/10"
            interrupt = Base.Event()
            download_task = @async request(url; interrupt)
            sleep(0.1)
            @test !istaskdone(download_task)
            notify(interrupt)
            timedwait(()->istaskdone(download_task), 5.0)
            @test istaskdone(download_task)
            @test download_task.result isa RequestError

            interrupt = Base.Event()
            url = "$server/put"
            input=`sh -c 'sleep 15; echo "hello"'`
            download_task = @async request(url; interrupt, input)
            sleep(0.1)
            @test !istaskdone(download_task)
            notify(interrupt)
            timedwait(()->istaskdone(download_task), 5.0)
            @test istaskdone(download_task)
            @test download_task.result isa RequestError
        end

        @testset "progress" begin
            url = "$server/drip"
            progress = []
            dl_funcs = [
                download,
                (url; progress) ->
                    request(url; progress, output=devnull)
            ]
            p_funcs = [
                (prog...) -> push!(progress, prog),
                (total, now) -> push!(progress, (total, now)),
                (total, now, _, _) -> push!(progress, (total, now)),
            ]
            for f in dl_funcs, p in p_funcs
                @testset "request" begin
                    empty!(progress)
                    f(url; progress = p)
                    @test progress[1][1] == 0
                    @test progress[1][2] == 0
                    @test progress[end][1] == 10
                    @test progress[end][2] == 10
                    @test issorted(p[1] for p in progress)
                    @test issorted(p[2] for p in progress)
                end
            end
        end
    end

    save_env = get(ENV, "JULIA_SSL_NO_VERIFY_HOSTS", nothing)
    delete!(ENV, "JULIA_SSL_NO_VERIFY_HOSTS")

    @testset "bad TLS" begin
        badssl = "badssl.julialang.org"
        urls = [
            "https://untrusted-root.$(badssl)"
            "https://wrong.host.$(badssl)"
        ]
        @testset "bad TLS is rejected" for url in urls
            resp = request(url, throw=false)
            @test resp isa RequestError
            @test resp.code == Curl.CURLE_PEER_FAILED_VERIFICATION
        end
        @testset "easy hook work-around" begin
            local url
            easy_hook = (easy, info) -> begin
                # don't verify anything (this disables SNI also)
                Curl.setopt(easy, Curl.CURLOPT_SSL_VERIFYPEER, false)
                Curl.setopt(easy, Curl.CURLOPT_SSL_VERIFYHOST, false)
                @test info.url == url
            end
            # downloader-specific easy hook
            downloader = Downloader()
            downloader.easy_hook = easy_hook
            for outer url in urls
                resp = request(url; downloader, throw=false)
                @test resp isa Response
                @test resp.status == 200
            end
            # default easy hook
            Downloads.EASY_HOOK[] = easy_hook
            Downloads.DOWNLOADER[] = nothing
            for outer url in urls
                resp = request(url, throw=false)
                @test resp isa Response
                @test resp.status == 200
            end
            Downloads.DOWNLOADER[] = nothing
            Downloads.EASY_HOOK[] = nothing
        end
        ENV["JULIA_SSL_NO_VERIFY_HOSTS"] = "**.$(badssl)"
        # wrong host *should* still fail, but may not due
        # to libcurl bugs when using non-OpenSSL backends:
        pop!(urls) # <= skip wrong host URL entirely here
        @testset "SSL no verify override" for url in urls
            resp = request(url, throw=false)
            @test resp isa Response
            @test resp.status == 200
        end
        delete!(ENV, "JULIA_SSL_NO_VERIFY_HOSTS")
    end

    @testset "SNI required" begin
        url = "https://juliahub.com" # anything served by CloudFront
        # secure verified host request
        resp = request(url, throw=false, downloader=Downloader())
        @test resp isa Response
        @test resp.status == 200
        # insecure unverified host request
        ENV["JULIA_SSL_NO_VERIFY_HOSTS"] = "**"
        resp = request(url, throw=false, downloader=Downloader())
        @test resp isa Response
        @test resp.status == 200
    end

    if save_env !== nothing
        ENV["JULIA_SSL_NO_VERIFY_HOSTS"] = save_env
    else
        delete!(ENV, "JULIA_SSL_NO_VERIFY_HOSTS")
    end

    @__MODULE__() == Main && @testset "ftp download" begin
        url = "ftp://ftp.gnu.org/gnu/auctex/auctex-13.3.tar.gz"
        file = Downloads.download(url)
        @test isfile(file)
        @test filesize(file) == 1695608
        head = String(read!(open(file), Vector{UInt8}(undef, 16)))
        @test head == "\x1f\x8b\b\0\0\0\0\0\x02\x03\xec[\xebr\xdb\xc6"
    end

    @testset "grace cleanup" begin
        dl = Downloader(grace=1)
        Downloads.download("$server/drip"; downloader=dl)
        Downloads.download("$server/drip"; downloader=dl)
    end

    @testset "Input body size" begin
        # Test mechanism to detect the body size from the request(; input) argument
        @test Downloads.arg_read_size(@__FILE__) == filesize(@__FILE__)
        @test Downloads.arg_read_size(IOBuffer("αa")) == 3
        @test Downloads.arg_read_size(IOBuffer(codeunits("αa"))) == 3  # Issue #142
        @test Downloads.arg_read_size(devnull) == 0
        @test Downloads.content_length(["Accept"=>"*/*",]) === nothing
        @test Downloads.content_length(["Accept"=>"*/*", "Content-Length"=>"100"]) == 100
    end
end

Downloads.DOWNLOADER[] = nothing
GC.gc(true)

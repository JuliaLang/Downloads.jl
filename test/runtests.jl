include("setup.jl")

@testset "Downloads.jl" begin
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
        path = download(url, headers=headers)
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
                @test output == download(url, output, headers=headers)
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
        data = download_json(url)
        @test "url" in keys(data)
        @test data["url"] == url
    end

    @testset "headers" begin
        url = "$server/headers"

        @testset "set headers" begin
            headers = ["Foo" => "123", "Header" => "VaLuE", "Empty" => ""]
            data = download_json(url, headers = headers)
            @test "headers" in keys(data)
            headers′ = data["headers"]
            for (key, value) in headers
                @test header(headers′, key) == value
            end
            @test header(headers′, "Accept") == "*/*"
        end

        @testset "override default header" begin
            headers = ["Accept" => "application/tar"]
            data = download_json(url, headers = headers)
            @test "headers" in keys(data)
            headers′ = data["headers"]
            @test header(headers′, "Accept") == "application/tar"
        end

        @testset "override default header with empty value" begin
            headers = ["Accept" => ""]
            data = download_json(url, headers = headers)
            @test "headers" in keys(data)
            headers′ = data["headers"]
            @test header(headers′, "Accept") == ""
        end

        @testset "delete default header" begin
            headers = ["Accept" => nothing]
            data = download_json(url, headers = headers)
            @test "headers" in keys(data)
            headers′ = data["headers"]
            @test !("Accept" in keys(headers′))
        end
    end

    @testset "errors" begin
        @test_throws ArgumentError download("ba\0d")
        @test_throws ArgumentError download("good", "ba\0d")

        err = @exception download("xyz://domain.invalid")
        @test err isa ErrorException
        @test startswith(err.msg, "Protocol \"xyz\" not supported")

        err = @exception download("https://domain.invalid")
        @test err isa ErrorException
        @test startswith(err.msg, "Could not resolve host")

        err = @exception download("$server/status/404")
        @test err isa ErrorException
        @test contains(err.msg, r"^HTTP/\d+(?:\.\d+)?\s+404\b")

        path = tempname()
        @test_throws ErrorException download("$server/status/404", path)
        @test !ispath(path)
    end

    @testset "concurrent requests" begin
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
                    data = download_json("$url?id=$id", downloader = downloader)
                    @test "args" in keys(data)
                    @test get(data["args"], "id", nothing) == ["$id"]
                end
            end
            @test t < 0.9*count*delay
            if have_lsof
                @test n_tcp == count_tcp()
            end
        end
    end

    @testset "request API" begin
        @testset "basic request usage" begin
            for status in (200, 300, 400)
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
            @test "foobar" in keys(headers)
            @test headers["foobar"] == "VaLuE"
        end

        @testset "url for redirect" begin
            url = "$server/get"
            redirect = "$server/redirect-to?url=$(url_escape(url))"
            resp, data = request_json(redirect)
            @test resp.url == url
            @test resp.status == 200
            test_response_string(resp.message, 200)
            @test "url" in keys(data)
            @test data["url"] == url
        end

        @testset "progress" begin
            url = "https://httpbingo.org/drip"
            @testset "request" begin
                progress = NTuple{4,Int}[]
                request(url; progress = (p...) -> push!(progress, p))
                @test progress[1][1] == 0
                @test progress[1][2] == 0
                @test progress[end][1] == 10
                @test progress[end][2] == 10
                @test issorted(p[1] for p in progress)
                @test issorted(p[2] for p in progress)
            end
            @testset "download" begin
                progress = NTuple{2,Int}[]
                download(url; progress = (p...) -> push!(progress, p))
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

Downloads.DOWNLOADER[] = nothing
GC.gc(true)

include("setup.jl")

@testset "Downloader.jl" begin
    @testset "get request" begin
        url = "$server/get"
        data = download_json(multi, url)
        @test "url" in keys(data)
        @test data["url"] == url
    end

    @testset "headers" begin
        url = "$server/headers"

        @testset "set headers" begin
            headers = ["Foo" => "123", "Header" => "VaLuE", "Empty" => ""]
            data = download_json(multi, url, headers)
            @test "headers" in keys(data)
            headers′ = data["headers"]
            for (key, value) in headers
                @test header(headers′, key) == value
            end
            @test header(headers′, "Accept") == "*/*"
        end

        @testset "override default header" begin
            headers = ["Accept" => "application/tar"]
            data = download_json(multi, url, headers)
            @test "headers" in keys(data)
            headers′ = data["headers"]
            @test header(headers′, "Accept") == "application/tar"
        end

        @testset "override default header with empty value" begin
            headers = ["Accept" => ""]
            data = download_json(multi, url, headers)
            @test "headers" in keys(data)
            headers′ = data["headers"]
            @test header(headers′, "Accept") == ""
        end

        @testset "delete default header" begin
            headers = ["Accept" => nothing]
            data = download_json(multi, url, headers)
            @test "headers" in keys(data)
            headers′ = data["headers"]
            @test !("Accept" in keys(headers′))
        end
    end

    @testset "concurrent requests" begin
        count = 10
        delay = 2
        url = "https://httpbin.org/delay/$delay"
        t = @elapsed @sync for id = 1:count
            @async begin
                data = download_json(multi, "$url?id=$id")
                @test "args" in keys(data)
                @test get(data["args"], "id", nothing) == "$id"
            end
        end
        @test 2t < count*delay
    end

    @testset "referer" begin
        dest = "$server/headers"
        url = "$server/redirect-to?url=$(url_escape(dest))"
        data = download_json(multi, url)
        @test "headers" in keys(data)
        headers′ = data["headers"]
        @test header(headers′, "Referer") == url
    end

    @testset "get API" begin
        @testset "basic get usage" begin
            for status in (200, 300, 400)
                url = "$server/status/$status"
                resp = get_body(multi, url)[1]
                @test resp.url == url
                @test resp.status == status
                test_response_string(resp.response, status)
                @test all(hdr isa Pair{String,String} for hdr in resp.headers)
                headers = Dict(resp.headers)
                @test "content-type" in keys(headers)
            end
        end

        @testset "custom headers" begin
            url = "$server/response-headers?FooBar=VaLuE"
            resp, data = get_body(multi, url)
            @test resp.url == url
            @test resp.status == 200
            test_response_string(resp.response, 200)
            headers = Dict(resp.headers)
            @test "foobar" in keys(headers)
            @test headers["foobar"] == "VaLuE"
        end

        @testset "url for redirect" begin
            dest = "$server/headers"
            url = "$server/redirect-to?url=$(url_escape(dest))"
            resp, data = get_json(multi, url)
            @test resp.url == dest
            @test resp.status == 200
            test_response_string(resp.response, 200)
            @test "headers" in keys(data)
            headers′ = data["headers"]
            @test header(headers′, "Referer") == url
        end

        @testset "progress" begin
            progress = Downloader.Curl.Progress[]
            # https://httpbingo.org/drop doesn't work
            req = Request(devnull, "https://httpbin.org/drip", String[])
            Downloader.get(req, multi, p -> push!(progress, p))
            unique!(progress)
            @test length(progress) == 11
            @test all(p.dl_total == 10(i≠1) for (i, p) in enumerate(progress))
            @test all(p.dl_now   == i-1     for (i, p) in enumerate(progress))
        end
    end
end

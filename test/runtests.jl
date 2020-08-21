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
end

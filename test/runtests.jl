using Test, JSON
using Downloader
using Downloader.Curl

function download_string(multi::Multi, url::AbstractString, headers = Union{}[])
    sprint() do io
        Downloader.download(multi, url, io, headers)
    end
end

function download_json(multi::Multi, url::AbstractString, headers = Union{}[])
    JSON.parse(download_string(multi, url, headers))
end

const server = "https://httpbin.org"

@testset "Downloader.jl" begin
    multi = Multi()

    @testset "get request" begin
        url = "$server/get"
        data = download_json(multi, url)
        @test "url" in keys(data)
        @test data["url"] == url
    end

    @testset "headers" begin
        url = "$server/headers"

        # test adding some headers
        headers = ["Foo" => "123", "Header" => "VaLuE", "Empty" => ""]
        data = download_json(multi, url, headers)
        @test "headers" in keys(data)
        headers′ = data["headers"]
        for (key, value) in headers
            @test headers′[key] == value
        end
        @test get(headers′, "Accept", nothing) == "*/*"

        # test setting overriding a default header
        headers = ["Accept" => "application/tar"]
        data = download_json(multi, url, headers)
        @test "headers" in keys(data)
        headers′ = data["headers"]
        @test get(headers′, "Accept", nothing) == "application/tar"

        # test setting overriding a default header with empty value
        headers = ["Accept" => ""]
        data = download_json(multi, url, headers)
        @test "headers" in keys(data)
        headers′ = data["headers"]
        @test get(headers′, "Accept", nothing) == ""

        # test deleting a default header
        headers = ["Accept" => nothing]
        data = download_json(multi, url, headers)
        @test "headers" in keys(data)
        headers′ = data["headers"]
        @test !("Accept" in keys(headers′))
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
end

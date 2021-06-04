using Pkg
using Test

@testset "Test that the UUID is unchanged" begin 
    project_filename = joinpath(dirname(@__DIR__), "Project.toml")
    project = Pkg.TOML.parsefile(project_filename)
    uuid = project["uuid"]
    correct_uuid = "f43a241f-c20a-4ad4-852c-f6b1247861c6"
    @test uuid == correct_uuid
end

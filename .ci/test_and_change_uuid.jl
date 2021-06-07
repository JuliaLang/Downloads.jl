@static if Base.VERSION >= v"1.6"
    using TOML
    using Test
else
    using Pkg: TOML
    using Test
end

# To generate the new UUID, we simply modify the first character of the original UUID
const original_uuid = "f43a241f-c20a-4ad4-852c-f6b1247861c6"
const new_uuid      = "e43a241f-c20a-4ad4-852c-f6b1247861c6"

# `@__DIR__` is the `.ci/` folder.
# Therefore, `dirname(@__DIR__)` is the repository root.
const project_filename = joinpath(dirname(@__DIR__), "Project.toml")

@testset "Test that the UUID is unchanged" begin
    project_dict = TOML.parsefile(project_filename)
    @test project_dict["uuid"] == original_uuid
end

write(
    project_filename,
    replace(
        read(project_filename, String),
        r"uuid = .*?\n" => "uuid = \"$(new_uuid)\"\n",
    ),
)

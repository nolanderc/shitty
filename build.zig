const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "use-llvm", "Use LLVM codegen");

    const exe = b.addExecutable(.{
        .name = "shitty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    b.installArtifact(exe);

    const c = b.createModule(.{ .root_source_file = b.path("src/c.zig"), .target = target, .optimize = optimize });
    exe.root_module.addImport("c", c);

    exe.root_module.addImport("tracy", tracyClient(b, .{ .target = target, .optimize = .ReleaseFast }));

    exe.linkLibC();
    exe.linkSystemLibrary("fontconfig");
    exe.linkSystemLibrary("freetype");
    exe.linkSystemLibrary("harfbuzz");
    exe.linkSystemLibrary("utf8proc");
    exe.linkSystemLibrary("X11");
    exe.linkSystemLibrary("xrender");
    exe.linkSystemLibrary("xcb");
    exe.linkSystemLibrary("xcb-render");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn tracyClient(b: *std.Build, args: anytype) *std.Build.Module {
    const module = b.addModule("tracy", .{ .root_source_file = b.path("src/tracy.zig") });
    const options = b.addOptions();
    module.addOptions("options", options);

    const enable = b.option(bool, "tracy", "Enable Tracy profiler") orelse false;
    options.addOption(bool, "enabled", enable);

    if (enable) {
        const dep = b.dependency("tracy", .{});

        const c = b.addTranslateC(.{
            .root_source_file = dep.path("public/tracy/TracyC.h"),
            .target = args.target,
            .optimize = .ReleaseFast,
        });
        c.defineCMacro("TRACY_ENABLE", "1");

        const lib = b.addStaticLibrary(.{
            .name = "TracyClient",
            .root_module = b.createModule(.{
                .root_source_file = c.getOutput(),
                .target = args.target,
                .optimize = .ReleaseFast,
            }),
        });
        lib.addCSourceFile(.{
            .file = dep.path("public/TracyClient.cpp"),
            .flags = &.{"-DTRACY_ENABLE=1"},
        });
        lib.linkLibC();
        lib.linkLibCpp();
        lib.addIncludePath(dep.path("public"));

        module.addImport("TracyC.h", lib.root_module);
        module.linkLibrary(lib);
    }

    return module;
}

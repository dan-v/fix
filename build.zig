const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(bool, "profile", "Keep symbols and frame pointers for profiling") orelse false;
    const vm_opcode_profile = b.option(bool, "vm-opcode-profile", "Collect and print VM opcode execution counts") orelse false;
    const debug_checks_opt = b.option(bool, "debug-checks", "Enable VM dispatch invariant assertions (defaults to Debug builds)");
    const vm_trace = b.option(bool, "vm-trace", "Enable VM execution tracing (--vm-trace)") orelse false;
    const strip: ?bool = if (profile) false else null;
    const omit_frame_pointer: ?bool = if (profile) false else null;
    const debug_checks = debug_checks_opt orelse (optimize == .Debug);
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const build_options = b.addOptions();
    build_options.addOption(bool, "vm_opcode_profile", vm_opcode_profile);
    build_options.addOption(bool, "debug_checks", debug_checks);
    build_options.addOption(bool, "vm_trace", vm_trace);

    const mod = b.addModule("fix", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    mod.addOptions("build_options", build_options);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    const harness_mod = b.createModule(.{
        .root_source_file = b.path("test/harness.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe_mod = b.createModule(.{
        // b.createModule defines a new module just like b.addModule but,
        // unlike b.addModule, it does not expose the module to consumers of
        // this package, which is why in this case we don't have to give it a name.
        .root_source_file = b.path("src/main.zig"),
        // Target and optimization levels must be explicitly wired in when
        // defining an executable or library (in the root module), and you
        // can also hardcode a specific target for an executable or library
        // definition if desireable (e.g. firmware for embedded devices).
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
        // List of modules available for import in source files part of the
        // root module.
        .imports = &.{
            // Here "fix" is the name you will use in your source code to
            // import this module (e.g. `@import("fix")`). The name is
            // repeated because you are allowed to rename your imports, which
            // can be extremely useful in case of collisions (which can happen
            // importing modules from different packages).
            .{ .name = "fix", .module = mod },
        },
    });
    exe_mod.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "fix",
        .root_module = exe_mod,
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    const integration_diff_exe = b.addExecutable(.{
        .name = "integration-diff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration_diff.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .omit_frame_pointer = omit_frame_pointer,
            .imports = &.{
                .{ .name = "fix-cli", .module = cli_mod },
                .{ .name = "harness", .module = harness_mod },
            },
        }),
    });

    const nixpkgs_check_exe = b.addExecutable(.{
        .name = "nixpkgs-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/nixpkgs_check.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .omit_frame_pointer = omit_frame_pointer,
            .imports = &.{
                .{ .name = "harness", .module = harness_mod },
            },
        }),
    });

    const integration_step = b.step("integration-test", "Run differential integration tests against nix-instantiate");
    const integration_cmd = b.addRunArtifact(integration_diff_exe);
    integration_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        integration_cmd.addArgs(args);
    }
    integration_step.dependOn(&integration_cmd.step);

    const diff_fuzz_step = b.step("diff-fuzz", "Run longer differential fuzzing against nix-instantiate");
    const diff_fuzz_cmd = b.addRunArtifact(integration_diff_exe);
    diff_fuzz_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        diff_fuzz_cmd.addArgs(args);
    }
    diff_fuzz_step.dependOn(&diff_fuzz_cmd.step);

    const nixpkgs_check_step = b.step("nixpkgs-check", "Compare nixpkgs package derivation paths against Nix");
    const nixpkgs_check_cmd = b.addRunArtifact(nixpkgs_check_exe);
    nixpkgs_check_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        nixpkgs_check_cmd.addArgs(args);
    }
    nixpkgs_check_step.dependOn(&nixpkgs_check_cmd.step);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const integration_diff_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration_diff.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .omit_frame_pointer = omit_frame_pointer,
            .imports = &.{
                .{ .name = "fix-cli", .module = cli_mod },
                .{ .name = "harness", .module = harness_mod },
            },
        }),
    });
    const run_integration_diff_tests = b.addRunArtifact(integration_diff_tests);

    const nixpkgs_check_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/nixpkgs_check.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .omit_frame_pointer = omit_frame_pointer,
            .imports = &.{
                .{ .name = "harness", .module = harness_mod },
            },
        }),
    });
    const run_nixpkgs_check_tests = b.addRunArtifact(nixpkgs_check_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_integration_diff_tests.step);
    test_step.dependOn(&run_nixpkgs_check_tests.step);

    const check_step = b.step("check", "Run unit and integration tests");
    check_step.dependOn(test_step);
    check_step.dependOn(integration_step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

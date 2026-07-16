const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(bool, "profile", "Keep symbols and frame pointers for profiling") orelse false;
    const debug_checks_opt = b.option(bool, "debug-checks", "Enable VM dispatch invariant assertions (defaults to Debug builds)");
    const vm_trace = b.option(bool, "vm-trace", "Enable VM execution tracing (--vm-trace)") orelse false;
    const thunks_log = b.option(bool, "thunks-log", "Enable per-thunk lifecycle event log (--thunks-log)") orelse false;
    const prof_main = b.option(bool, "prof-main", "Time main thread's hot serial paths via rdtsc; print via --print-sched-stats") orelse false;
    const prof_path = b.option(bool, "prof-path", "Record the force-call tree (workers=1) and report the critical path + source-attributed profile; print via --print-sched-stats") orelse false;
    const strip: ?bool = if (profile) false else null;
    const omit_frame_pointer: ?bool = if (profile) false else null;
    const debug_checks = debug_checks_opt orelse (optimize == .Debug);

    const build_options = b.addOptions();
    build_options.addOption(bool, "debug_checks", debug_checks);
    build_options.addOption(bool, "vm_trace", vm_trace);
    build_options.addOption(bool, "thunks_log", thunks_log);
    build_options.addOption(bool, "prof_main", prof_main);
    build_options.addOption(bool, "prof_path", prof_path);
    // One shared module instance for every evaluator file that uses build flags.
    const build_options_mod = build_options.createModule();

    const base_options = b.addOptions();
    base_options.addOption(bool, "fiber_census", prof_main);
    const base_options_mod = base_options.createModule();

    // Keep build modules for the boundaries that are independently reusable or
    // consumed. Subsystems inside `nix` are ordinary files exported by its root.
    // This keeps the permanent graph small and lets Zig's normal file imports
    // provide one canonical instance of every internal type.
    const syntax_mod = b.addModule("syntax", .{
        .root_source_file = b.path("src/syntax/syntax.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });

    // The LALR parser tables are expensive to construct at comptime, so a
    // standalone codegen tool builds them once (cached by the build system;
    // only rebuilt when the grammar or generator changes) and emits a plain
    // `.zig` of literal arrays. The `syntax` module imports it as
    // `@import("parser_tables")`, keeping the cost off every ordinary rebuild.
    const gen_tables_exe = b.addExecutable(.{
        .name = "gen-parser-tables",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/syntax/gen_parser_tables.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
        .use_llvm = true,
    });
    const run_gen_tables = b.addRunArtifact(gen_tables_exe);
    const parser_tables_path = run_gen_tables.addOutputFileArg("parser_tables.zig");
    syntax_mod.addAnonymousImport("parser_tables", .{ .root_source_file = parser_tables_path });
    const gen_tables_step = b.step("gen-parser-tables", "Regenerate the LALR parser tables");
    gen_tables_step.dependOn(&run_gen_tables.step);

    // Generic, reusable infrastructure with zero Nix coupling.
    const base_mod = b.addModule("base", .{
        .root_source_file = b.path("src/base/base.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    base_mod.addImport("base_options", base_options_mod);
    syntax_mod.addImport("base", base_mod);

    const runtime_mod = b.addModule("runtime", .{
        .root_source_file = b.path("src/runtime/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    runtime_mod.addImport("build_options", build_options_mod);
    runtime_mod.addImport("base", base_mod);

    const nix_mod = b.addModule("nix", .{
        .root_source_file = b.path("src/nix/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    nix_mod.addImport("build_options", build_options_mod);
    nix_mod.addImport("syntax", syntax_mod);
    nix_mod.addImport("runtime", runtime_mod);
    nix_mod.addImport("base", base_mod);

    const cli_mod = b.addModule("cli", .{
        .root_source_file = b.path("src/cli/cli.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    cli_mod.addImport("nix", nix_mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
        .imports = &.{
            .{ .name = "nix", .module = nix_mod },
            .{ .name = "cli", .module = cli_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "fix",
        .root_module = exe_mod,
        // The threaded VM dispatcher in src/nix/vm/run.zig relies on
        // `@call(.always_tail)`, which only the LLVM backend
        // implements. Force LLVM for every build mode so debug
        // builds don't unbounded-recurse through the dispatch
        // chain.
        .use_llvm = true,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const base_tests = b.addTest(.{
        .root_module = base_mod,
        .use_llvm = true,
    });
    const run_base_tests = b.addRunArtifact(base_tests);

    const runtime_tests = b.addTest(.{
        .root_module = runtime_mod,
        .use_llvm = true,
    });
    const run_runtime_tests = b.addRunArtifact(runtime_tests);

    const syntax_tests = b.addTest(.{
        .root_module = syntax_mod,
        .use_llvm = true,
    });
    const run_syntax_tests = b.addRunArtifact(syntax_tests);

    const nix_tests = b.addTest(.{
        .root_module = nix_mod,
        .use_llvm = true,
    });
    const run_nix_tests = b.addRunArtifact(nix_tests);

    const cli_tests = b.addTest(.{
        .root_module = cli_mod,
        .use_llvm = true,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_base_tests.step);
    test_step.dependOn(&run_syntax_tests.step);
    test_step.dependOn(&run_runtime_tests.step);
    test_step.dependOn(&run_nix_tests.step);
    test_step.dependOn(&run_cli_tests.step);

    const check_step = b.step("check", "Run unit tests");
    check_step.dependOn(test_step);

    // Quick syntax-only tests. The parser imports the build-generated
    // `parser_tables`, so `zig test src/syntax/parser.zig` can't resolve it on
    // its own — use this instead for fast iteration on the lexer/parser/AST.
    const test_syntax_step = b.step("test-syntax", "Run only the syntax (lexer/parser/AST) tests");
    test_syntax_step.dependOn(&run_syntax_tests.step);

    // Parse microbenchmark: `zig build bench -- <file.nix> ...`
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/parse_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("syntax", syntax_mod);
    const bench_exe = b.addExecutable(.{ .name = "parse-bench", .root_module = bench_mod, .use_llvm = true });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Parse microbenchmark");
    bench_step.dependOn(&run_bench.step);

    // Language conformance: run the pinned Lix + snix language test corpora
    // (see test/lang/) against the freshly built `fix`. This is a differential
    // suite, not a unit test — it needs Nix (to resolve the npins pins) and a
    // python3 (the wrapper borrows one from nix-shell if none is on PATH), and
    // it exits non-zero while any case diverges. Pass runner flags through, e.g.
    // `zig build test-lang -- --suite lix -v`.
    const lang_step = b.step("test-lang", "Run the Lix + snix language conformance suites against fix");
    const run_lang = b.addSystemCommand(&.{"bash"});
    run_lang.addFileArg(b.path("test/lang/run.sh"));
    run_lang.step.dependOn(b.getInstallStep());
    run_lang.has_side_effects = true;
    // Capture both streams so the step does not inherit stdio: Zig only hands a
    // child the std.Progress IPC pipe (ZIG_PROGRESS) when nothing is inherited
    // (see std/Build/Step/Run.zig — `if (!disable_zig_progress and !inherit)`).
    // The harness draws its live lix/snix tree over that pipe and writes its
    // pass/fail report to stderr, which Zig surfaces if the step fails.
    _ = run_lang.captureStdOut(.{});
    _ = run_lang.captureStdErr(.{});
    if (b.args) |args| run_lang.addArgs(args);
    lang_step.dependOn(&run_lang.step);
}

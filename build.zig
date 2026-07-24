const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(bool, "profile", "Keep symbols and frame pointers for profiling") orelse false;
    const debug_checks_opt = b.option(bool, "debug-checks", "Enable VM dispatch invariant assertions (defaults to Debug builds)");
    const vm_trace = b.option(bool, "vm-trace", "Enable VM execution tracing (--vm-trace)") orelse false;
    const thunks_log = b.option(bool, "thunks-log", "Enable per-thunk lifecycle event log (--thunks-log)") orelse false;
    const prof_main = b.option(bool, "prof-main", "Time main thread's hot serial paths via rdtsc; print via --stats") orelse false;
    const prof_path = b.option(bool, "prof-path", "Record the force-call tree (workers=1) and report the critical path + source-attributed profile; print via --stats") orelse false;
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

    // Keep build modules for durable domain boundaries. Internal subsystems use
    // ordinary file imports beneath these roots so each type has one canonical
    // instance without restating every file edge in the build graph.
    const syntax_mod = b.addModule("syntax", .{
        .root_source_file = b.path("src/syntax/root.zig"),
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
        .root_source_file = b.path("src/base/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    base_mod.addImport("base_options", base_options_mod);
    syntax_mod.addImport("base", base_mod);

    const runtime_mod = b.addModule("runtime", .{
        .root_source_file = b.path("src/runtime/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    runtime_mod.addImport("build_options", build_options_mod);
    runtime_mod.addImport("base", base_mod);

    const store_mod = b.addModule("store", .{
        .root_source_file = b.path("src/store/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    store_mod.addImport("runtime", runtime_mod);
    store_mod.addImport("base", base_mod);

    const fetchers_mod = b.addModule("fetchers", .{
        .root_source_file = b.path("src/fetchers/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    fetchers_mod.addImport("runtime", runtime_mod);
    fetchers_mod.addImport("base", base_mod);
    fetchers_mod.addImport("store", store_mod);
    fetchers_mod.linkSystemLibrary("libcurl", .{ .use_pkg_config = .force });
    fetchers_mod.linkSystemLibrary("libgit2", .{ .use_pkg_config = .force });
    fetchers_mod.link_libc = true;

    const expr_mod = b.addModule("expr", .{
        .root_source_file = b.path("src/expr/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    expr_mod.addImport("build_options", build_options_mod);
    expr_mod.addImport("syntax", syntax_mod);
    expr_mod.addImport("runtime", runtime_mod);
    expr_mod.addImport("base", base_mod);
    expr_mod.addImport("store", store_mod);
    expr_mod.addImport("fetchers", fetchers_mod);

    const cli_mod = b.addModule("cli", .{
        .root_source_file = b.path("src/cli/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    cli_mod.addImport("base", base_mod);
    cli_mod.addImport("expr", expr_mod);
    cli_mod.addImport("runtime", runtime_mod);
    cli_mod.addImport("syntax", syntax_mod);
    cli_mod.addImport("store", store_mod);

    const process_support_mod = b.createModule(.{
        .root_source_file = b.path("src/process_support.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "base", .module = base_mod },
            .{ .name = "runtime", .module = runtime_mod },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
        .imports = &.{
            .{ .name = "cli", .module = cli_mod },
            .{ .name = "process_support", .module = process_support_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "fix",
        .root_module = exe_mod,
        // The threaded VM dispatcher in src/expr/vm/run.zig relies on
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

    const expr_tests = b.addTest(.{
        .root_module = expr_mod,
        .use_llvm = true,
    });
    const run_expr_tests = b.addRunArtifact(expr_tests);

    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("src/integration/expr_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "expr", .module = expr_mod },
            .{ .name = "runtime", .module = runtime_mod },
        },
    });
    const integration_tests = b.addTest(.{
        .root_module = integration_test_mod,
        .use_llvm = true,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const fetchers_tests = b.addTest(.{
        .root_module = fetchers_mod,
        .use_llvm = true,
    });
    const run_fetchers_tests = b.addRunArtifact(fetchers_tests);

    const store_tests = b.addTest(.{
        .root_module = store_mod,
        .use_llvm = true,
    });
    const run_store_tests = b.addRunArtifact(store_tests);

    const cli_tests = b.addTest(.{
        .root_module = cli_mod,
        .use_llvm = true,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_base_tests.step);
    test_step.dependOn(&run_syntax_tests.step);
    test_step.dependOn(&run_runtime_tests.step);
    test_step.dependOn(&run_store_tests.step);
    test_step.dependOn(&run_fetchers_tests.step);
    test_step.dependOn(&run_expr_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_cli_tests.step);

    const format_check = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "tools" },
        .check = true,
    });

    const check_step = b.step("check", "Check formatting and run unit tests");
    check_step.dependOn(&format_check.step);
    check_step.dependOn(test_step);

    // Quick syntax-only tests. The parser imports the build-generated
    // `parser_tables`, so `zig test src/syntax/parser.zig` can't resolve it on
    // its own — use this instead for fast iteration on the lexer/parser/AST.
    const test_syntax_step = b.step("test-syntax", "Run only the syntax (lexer/parser/AST) tests");
    test_syntax_step.dependOn(&run_syntax_tests.step);

    // Parse microbenchmark: `zig build bench-parse -- <file.nix> ...`. Named to
    // avoid colliding with the differential *eval* benchmark (nix/bench.nix,
    // driven by ./bench.sh) — this one times the front-end parser alone.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/parse_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("syntax", syntax_mod);
    const bench_exe = b.addExecutable(.{ .name = "parse-bench", .root_module = bench_mod, .use_llvm = true });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench-parse", "Parse microbenchmark (front-end only; eval benchmark lives in nix/bench.nix)");
    bench_step.dependOn(&run_bench.step);

    // Language conformance: run the pinned Lix + snix language test corpora
    // (see test/lang/) against the freshly built `fix`. This is a differential
    // suite, not a unit test — the hand-rolled Zig runner (test/lang/*.zig)
    // needs only Nix (to resolve the npins pins), drives `fix` per case, and
    // exits non-zero while any case diverges. Pass runner flags through, e.g.
    // `zig build test-lang -- --suite lix`. libc is linked for the POSIX
    // special-file creation (mkfifo/mknod) the snix fixtures need.
    const lang_step = b.step("test-lang", "Run the Lix + snix language conformance suites against fix");
    const lang_exe = b.addExecutable(.{
        .name = "lang-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/lang/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    const run_lang = b.addRunArtifact(lang_exe);
    run_lang.step.dependOn(b.getInstallStep());
    run_lang.has_side_effects = true;
    run_lang.addArg("--repo");
    run_lang.addArg(b.pathFromRoot("."));
    run_lang.addArg("--fix");
    run_lang.addArg(b.pathFromRoot("zig-out/bin/fix"));
    if (b.args) |args| run_lang.addArgs(args);
    lang_step.dependOn(&run_lang.step);

    // Bench-fixture differential correctness: evaluate every bench/workloads
    // fixture under fix and a reference Nix and compare (NOT a timing run — it
    // reuses the fixtures to confirm agreement). Needs Nix + the pinned nixpkgs.
    // e.g. `zig build test-bench-fixtures -- torture`.
    const bench_check_step = b.step("test-bench-fixtures", "Differentially check bench fixtures: fix vs reference Nix");
    const bench_check_exe = b.addExecutable(.{
        .name = "bench-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bench_check.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    const run_bench_check = b.addRunArtifact(bench_check_exe);
    run_bench_check.step.dependOn(b.getInstallStep());
    run_bench_check.has_side_effects = true;
    run_bench_check.addArg("--repo");
    run_bench_check.addArg(b.pathFromRoot("."));
    run_bench_check.addArg("--fix");
    run_bench_check.addArg(b.pathFromRoot("zig-out/bin/fix"));
    if (b.args) |args| run_bench_check.addArgs(args);
    bench_check_step.dependOn(&run_bench_check.step);

    // End-to-end CLI suites (test/e2e/): drive the freshly built `fix` through
    // behavioral checks (repl pipe+PTY contract, `fix flake` subcommands, ...).
    // Adding coverage is dropping a `test/e2e/<name>.sh` fragment. Pipe-mode
    // checks run everywhere; PTY checks self-skip without a util-linux script(1)
    // (e.g. macOS). Part of `zig build test`, and runnable alone, e.g.
    // `zig build test-e2e -- flake`.
    const e2e_step = b.step("test-e2e", "Run the end-to-end CLI suites (test/e2e/) against fix");
    const run_e2e = b.addSystemCommand(&.{"bash"});
    run_e2e.addFileArg(b.path("test/e2e/run.sh"));
    run_e2e.step.dependOn(b.getInstallStep());
    run_e2e.has_side_effects = true;
    if (b.args) |args| run_e2e.addArgs(args);
    e2e_step.dependOn(&run_e2e.step);
    test_step.dependOn(&run_e2e.step);
}

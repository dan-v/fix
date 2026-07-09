const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(bool, "profile", "Keep symbols and frame pointers for profiling") orelse false;
    const vm_opcode_profile = b.option(bool, "vm-opcode-profile", "Collect and print VM opcode execution counts") orelse false;
    const debug_checks_opt = b.option(bool, "debug-checks", "Enable VM dispatch invariant assertions (defaults to Debug builds)");
    const vm_trace = b.option(bool, "vm-trace", "Enable VM execution tracing (--vm-trace)") orelse false;
    const thunks_log = b.option(bool, "thunks-log", "Enable per-thunk lifecycle event log (--thunks-log)") orelse false;
    const fiber_stack_probe = b.option(bool, "fiber-stack-probe", "Sentinel-fill fiber stacks to enable maxStackUsedBytes — forces full RSS commit") orelse false;
    const prof_main = b.option(bool, "prof-main", "Time main thread's hot serial paths via rdtsc; print via --print-sched-stats") orelse false;
    const prof_path = b.option(bool, "prof-path", "Record the force-call tree (workers=1) and report the critical path + source-attributed profile; print via --print-sched-stats") orelse false;
    const timeline = b.option(bool, "timeline", "Record a wall-clock event timeline (parse/compile/import phases, fiber-run quanta, idle parks) per worker; write Perfetto JSON via --timeline[=path].") orelse false;
    const gc = b.option(bool, "gc", "Include the generational collector (budget-gated via --max-memory, dormant below half-budget, ~2% rooting tax). ON by default; -Dgc=false builds the collector-free evaluator. See docs/gc.md.") orelse true;
    const strip: ?bool = if (profile) false else null;
    const omit_frame_pointer: ?bool = if (profile) false else null;
    const debug_checks = debug_checks_opt orelse (optimize == .Debug);

    const build_options = b.addOptions();
    build_options.addOption(bool, "vm_opcode_profile", vm_opcode_profile);
    build_options.addOption(bool, "debug_checks", debug_checks);
    build_options.addOption(bool, "vm_trace", vm_trace);
    build_options.addOption(bool, "thunks_log", thunks_log);
    build_options.addOption(bool, "fiber_stack_probe", fiber_stack_probe);
    build_options.addOption(bool, "prof_main", prof_main);
    build_options.addOption(bool, "prof_path", prof_path);
    build_options.addOption(bool, "timeline", timeline);
    build_options.addOption(bool, "gc", gc);
    // One shared module instance — importing the same `build_options` into
    // several modules (runtime, fix, exe) within one compilation requires the
    // SAME module object, else Zig sees the generated file in two modules.
    const build_options_mod = build_options.createModule();

    // Clean-cut subsystem modules: genuinely-acyclic subsystems are real
    // modules so consumers import them by name (`@import("syntax")`) and the
    // compiler enforces that nothing reaches into their internals. The coupled
    // evaluator engine stays in the main module (see docs/plans/cleanup-plan.md).
    const syntax_mod = b.addModule("syntax", .{
        .root_source_file = b.path("src/syntax.zig"),
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

    const containers_mod = b.addModule("containers", .{
        .root_source_file = b.path("src/containers.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });

    const runtime_mod = b.addModule("runtime", .{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    runtime_mod.addImport("build_options", build_options_mod);
    runtime_mod.addImport("containers", containers_mod);

    const parallel_mod = b.addModule("parallel", .{
        .root_source_file = b.path("src/parallel.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    parallel_mod.addImport("build_options", build_options_mod);
    parallel_mod.addImport("runtime", runtime_mod);
    parallel_mod.addImport("containers", containers_mod);
    // Fiber stack-switching primitive. The .S file is per-arch; pick one by the
    // resolved target. Lives with the fiber code in the parallel module.
    switch (target.result.cpu.arch) {
        .x86_64 => parallel_mod.addAssemblyFile(b.path("src/parallel/fiber/swap_x86_64.S")),
        else => @panic("unsupported architecture: stack-switching asm is only implemented for x86_64"),
    }

    const derivation_mod = b.addModule("derivation", .{
        .root_source_file = b.path("src/derivation.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    derivation_mod.addImport("runtime", runtime_mod);

    // Evaluation observability sinks (progress protocol + error-trace collector).
    // Leaf types the interpreter writes to; the evaluator/CLI implement them.
    const observ_mod = b.addModule("observ", .{
        .root_source_file = b.path("src/observ.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    observ_mod.addImport("syntax", syntax_mod);

    const mod = b.addModule("fix", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    const shared_imports: SharedImports = .{
        .build_options = build_options_mod,
        .syntax = syntax_mod,
        .runtime = runtime_mod,
        .parallel = parallel_mod,
        .derivation = derivation_mod,
        .containers = containers_mod,
        .observ = observ_mod,
    };
    addSharedImports(mod, shared_imports);

    const cli_mod = b.addModule("cli", .{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    cli_mod.addImport("fix", mod);
    addSharedImports(cli_mod, shared_imports);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
        .imports = &.{
            .{ .name = "fix", .module = mod },
            .{ .name = "cli", .module = cli_mod },
        },
    });
    addSharedImports(exe_mod, shared_imports);

    const exe = b.addExecutable(.{
        .name = "fix",
        .root_module = exe_mod,
        // The threaded VM dispatcher in src/vm/run.zig relies on
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

    const mod_tests = b.addTest(.{
        .root_module = mod,
        // Match the exe: threaded dispatcher needs LLVM tail calls.
        .use_llvm = true,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .use_llvm = true,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // `runtime`, `syntax`, `parallel`, `derivation`, and `containers` are each
    // separate modules (clean-cut subsystems, see the comment above
    // `syntax_mod`), so their unit tests aren't collected by the root-module
    // test artifacts above — Zig only walks a module's own `@import` graph,
    // and these are pulled into `fix` by module name, not by file inclusion.
    // Run each explicitly, the same way `runtime_tests` already was.
    const containers_tests = b.addTest(.{
        .root_module = containers_mod,
        .use_llvm = true,
    });
    const run_containers_tests = b.addRunArtifact(containers_tests);

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

    const parallel_tests = b.addTest(.{
        .root_module = parallel_mod,
        .use_llvm = true,
    });
    const run_parallel_tests = b.addRunArtifact(parallel_tests);

    const derivation_tests = b.addTest(.{
        .root_module = derivation_mod,
        .use_llvm = true,
    });
    const run_derivation_tests = b.addRunArtifact(derivation_tests);

    const cli_tests = b.addTest(.{
        .root_module = cli_mod,
        .use_llvm = true,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    // Module-boundary import lint (tools/lint_imports.zig). Catches relative
    // imports that reach into a clean-cut module's files instead of going
    // through `@import("<module>")` — those silently duplicate-compile.
    const lint_exe = b.addExecutable(.{
        .name = "lint-imports",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lint_imports.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_lint = b.addRunArtifact(lint_exe);
    const lint_step = b.step("lint", "Check module-boundary import hygiene");
    lint_step.dependOn(&run_lint.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lint.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_runtime_tests.step);
    test_step.dependOn(&run_syntax_tests.step);
    test_step.dependOn(&run_parallel_tests.step);
    test_step.dependOn(&run_derivation_tests.step);
    test_step.dependOn(&run_containers_tests.step);
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
}

const SharedImports = struct {
    build_options: *std.Build.Module,
    syntax: *std.Build.Module,
    runtime: *std.Build.Module,
    parallel: *std.Build.Module,
    derivation: *std.Build.Module,
    containers: *std.Build.Module,
    observ: *std.Build.Module,
};

fn addSharedImports(module: *std.Build.Module, imports: SharedImports) void {
    module.addImport("build_options", imports.build_options);
    module.addImport("syntax", imports.syntax);
    module.addImport("runtime", imports.runtime);
    module.addImport("parallel", imports.parallel);
    module.addImport("derivation", imports.derivation);
    module.addImport("containers", imports.containers);
    module.addImport("observ", imports.observ);
}

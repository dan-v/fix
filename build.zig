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
    const jit = b.option(bool, "jit", "Enable the experimental native-code JIT (x86_64 Linux only)") orelse false;
    const prof_main = b.option(bool, "prof-main", "Time main thread's hot serial paths via rdtsc; print via --print-sched-stats") orelse false;
    const prof_path = b.option(bool, "prof-path", "Record the force-call tree (workers=1) and report the critical path + source-attributed profile; print via --print-sched-stats") orelse false;
    const trace_probe = b.option(bool, "trace-probe", "Measure tracing-JIT headroom: per-thunk read-count histogram (single-use vs shared) + body-size distribution. Run at --workers=1.") orelse false;
    const struct_census = b.option(bool, "struct-census", "Measure deforestation headroom: per-list/attrset consume-count histogram (single-use vs shared). Run at --workers=1.") orelse false;
    const drv_probe = b.option(bool, "drv-probe", "Measure derivation-build demand: per-attr resolved-ahead vs forced-inline, fanout ok/rej, and serial input-DAG depth/fan-in. Depth meaningful only at --workers=1.") orelse false;
    const opcode_ngram = b.option(bool, "opcode-ngram", "Profile hottest adjacent (fall-through) opcode pairs for superinstruction fusion. Run at --workers=1.") orelse false;
    const tjit = b.option(bool, "tjit", "Experimental tracing/inlining JIT (records hot force/call traces, inlines + sinks allocations, compiles to native with deopt guards). See docs/plans/tracing-jit.md. Off by default; interpreter stays canonical.") orelse false;
    const timeline = b.option(bool, "timeline", "Record a wall-clock event timeline (parse/compile/import phases, fiber-run quanta, idle parks) per worker; write Perfetto JSON via --timeline[=path].") orelse false;
    const gc = b.option(bool, "gc", "GC Phase 0: sample the live set periodically during eval (mark from roots, no reclaim) and report peak-live vs total-allocated — the reclaimable-RSS headroom. Run at --workers=1. See docs/plans/gc-plan.md.") orelse false;
    const depth0_probe = b.option(bool, "depth0-probe", "Measure concurrent-SATB snapshot feasibility: at each forceThunk safepoint record native_depth + allocation cursor; report the depth-0 vs depth>0 split, the max allocation gap between depth-0 points (the RSS float), and a banded timeline. Run at --workers=1 WITHOUT -Dgc.") orelse false;
    const strip: ?bool = if (profile) false else null;
    const omit_frame_pointer: ?bool = if (profile) false else null;
    const debug_checks = debug_checks_opt orelse (optimize == .Debug);

    const build_options = b.addOptions();
    build_options.addOption(bool, "vm_opcode_profile", vm_opcode_profile);
    build_options.addOption(bool, "debug_checks", debug_checks);
    build_options.addOption(bool, "vm_trace", vm_trace);
    build_options.addOption(bool, "thunks_log", thunks_log);
    build_options.addOption(bool, "fiber_stack_probe", fiber_stack_probe);
    build_options.addOption(bool, "jit", jit);
    build_options.addOption(bool, "prof_main", prof_main);
    build_options.addOption(bool, "prof_path", prof_path);
    build_options.addOption(bool, "trace_probe", trace_probe);
    build_options.addOption(bool, "struct_census", struct_census);
    build_options.addOption(bool, "drv_probe", drv_probe);
    build_options.addOption(bool, "opcode_ngram", opcode_ngram);
    build_options.addOption(bool, "tjit", tjit);
    build_options.addOption(bool, "timeline", timeline);
    build_options.addOption(bool, "gc", gc);
    build_options.addOption(bool, "depth0_probe", depth0_probe);
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

    const runtime_mod = b.addModule("runtime", .{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    runtime_mod.addImport("build_options", build_options_mod);

    const parallel_mod = b.addModule("parallel", .{
        .root_source_file = b.path("src/parallel.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
    });
    parallel_mod.addImport("build_options", build_options_mod);
    parallel_mod.addImport("runtime", runtime_mod);
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
    };
    addSharedImports(mod, shared_imports);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
        .imports = &.{
            .{ .name = "fix", .module = mod },
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

    // `runtime`, `syntax`, `parallel`, and `derivation` are each separate
    // modules (clean-cut subsystems, see the comment above `syntax_mod`), so
    // their unit tests aren't collected by the root-module test artifacts
    // above — Zig only walks a module's own `@import` graph, and these are
    // pulled into `fix` by module name, not by file inclusion. Run each
    // explicitly, the same way `runtime_tests` already was.
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

    const check_step = b.step("check", "Run unit tests");
    check_step.dependOn(test_step);
}

const SharedImports = struct {
    build_options: *std.Build.Module,
    syntax: *std.Build.Module,
    runtime: *std.Build.Module,
    parallel: *std.Build.Module,
    derivation: *std.Build.Module,
};

fn addSharedImports(module: *std.Build.Module, imports: SharedImports) void {
    module.addImport("build_options", imports.build_options);
    module.addImport("syntax", imports.syntax);
    module.addImport("runtime", imports.runtime);
    module.addImport("parallel", imports.parallel);
    module.addImport("derivation", imports.derivation);
}

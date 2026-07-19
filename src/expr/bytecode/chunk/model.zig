//! Immutable bytecode chunk model.
//!
//! Chunks are immutable after construction. They are identified by ChunkId
//! in a global table, enabling cheap interning and cross-thread referencing.

const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const AttrEntry = @import("runtime").heap.AttrEntry;
const AttrPosEntry = @import("runtime").heap.AttrPosEntry;
const ChunkId = types.ChunkId;

/// The formal-parameter pattern of a lambda chunk, carried so `--xml`
/// output can render `<varpat>`/`<attrspat>` the way Nix does. `none` for
/// non-lambda (thunk) bodies, builtins, and merged bodies with no param
/// info. Semantically distinguishing (two identity lambdas `x: x` and
/// `y: y` compile to identical bytecode but render different varpat names),
/// so it participates in chunk dedup (`contentHash`/`contentEql`).
pub const LambdaPattern = union(enum) {
    none,
    /// `x: …` (value lambda; for a merged `a: b: …` chain, the first param).
    var_pat: types.InternId,
    /// `{a, b, …}: …` / `args@{…}: …`. Formal names come from `function_args`.
    attrs_pat: AttrsPattern,

    pub const AttrsPattern = struct {
        /// The `@`-binding name (`args` in `args@{…}`); valid iff `has_bind`.
        bind_name: types.InternId = 0,
        has_bind: bool = false,
        /// The pattern ends in `...` (accepts extra attrs).
        ellipsis: bool = false,
    };
};

pub const Chunk = struct {
    pub const SourceSpan = struct {
        file: ?types.InternId,
        offset: u32,
        len: u32,
        line: u32,
        column: u32,
    };

    pub const SourceMapEntry = struct {
        start: u32,
        end: u32,
        span: SourceSpan,
    };

    /// Bytecode stream.
    code: []u8,
    /// Constant pool.
    constants: []Value,
    /// Number of stack slots reserved for locals in each frame.
    local_count: u16,
    /// Number of parameters the function consumes before its body runs.
    /// 1 for curried or attrset lambdas and for
    /// thunk bodies (which are never "called"). N>1 for an *uncurried*
    /// chunk produced by merging an adjacent `a: b: ...:` value-lambda
    /// chain (see `compiler/lambda.zig compileLambda`): a call site
    /// supplying N args runs the body in one frame, under-application
    /// builds a partial-application (PAP) value. `arity <= local_count`.
    arity: u16 = 1,
    /// Bitmask (bit i = param i) of which params an *uncurried* (arity>1)
    /// chunk's body unconditionally forces — the multi-param analogue of
    /// `scheduling.strict_param`. The saturated `call_n` path eagerly
    /// forces these arg positions before running the body, recovering the
    /// eager-arg optimization the single-param path gets via `thunk_arg`
    /// (and avoiding lazy-thunk-chain buildup in accumulator recursion).
    /// 0 for arity-1 chunks (handled by `strict_param`) and thunk bodies.
    strict_params: u8 = 0,
    /// Compile-time scheduling hints — `body_is_substantial`
    /// (chunk-size driven, pays the scheduler hop) and `strictness`
    /// (which upvalues the body unconditionally forces). Both are
    /// stamped at `ChunkBuilder.finish()` time and consumed by the VM
    /// to decide whether to submit a thunk for parallel forcing at
    /// creation. See `compiler/strictness.zig` for the strictness
    /// analysis.
    scheduling: SchedulingHints = .{},
    /// Attrset function parameter metadata for builtins.functionArgs.
    function_args: []const AttrEntry = &.{},
    /// Source positions of the function parameters (parallel data for
    /// `builtins.functionArgs`), so `unsafeGetAttrPos` can report a formal's
    /// location. Empty when the chunk was compiled without a source path.
    function_arg_pos: []const AttrPosEntry = &.{},
    /// Attr-position records referenced by `attrs_new_named_pos_srt` ops.
    /// Kept outside dispatched code because only diagnostics read them; ops
    /// carry a `(start, count)` reference.
    attr_pos: []const AttrPosEntry = &.{},
    /// Attr names referenced by `attrs_new_named*` ops (interned ids, sorted
    /// per site) — like `attr_pos`, kept out of the code stream; each op
    /// carries a (start, count) reference.
    attr_names: []const types.InternId = &.{},
    /// Capture-descriptor lists referenced by `thunk_defer` (and, later, the
    /// thunk family) — kept OUT of the code stream and DEDUPED, like `attr_pos`.
    /// Identical `(kind:1, index:2)*` lists share a range referenced by
    /// `(start, count)`. Read via `captureList`.
    capture_bytes: []const u8 = &.{},
    /// Source span ranges for cold-path error traces.
    source_map: []const SourceMapEntry = &.{},
    /// The span of the whole body node this chunk was compiled from — a
    /// representative source location for the chunk even when `source_map` is
    /// empty (it's sparse: entries are added only for tail apply/if/let/…
    /// constructs). Used by the timeline to label a thunk quantum / demand
    /// wait. Set at `stampOnBuilder`; null for chunks that skip it.
    body_span: ?SourceSpan = null,
    /// Formal-parameter pattern for `--xml` function rendering. See the type.
    lambda_pattern: LambdaPattern = .none,

    /// The capture-descriptor bytes for a `(start, count)` reference: `count`
    /// `(kind:1, index:2)` triples starting at `start` in `capture_bytes`.
    pub fn captureList(self: *const Chunk, start: u32, count: u16) []const u8 {
        return self.capture_bytes[start .. start + @as(usize, count) * 3];
    }

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.constants);
        allocator.free(self.function_args);
        allocator.free(self.function_arg_pos);
        allocator.free(self.attr_pos);
        allocator.free(self.attr_names);
        allocator.free(self.capture_bytes);
        allocator.free(self.source_map);
    }
};

/// Compile-time signal of which upvalues a chunk's body will force.
/// Two depths:
///   `forced_upvalues` — forced when the body is evaluated to WHNF
///       (always, since entering a chunk runs its body).
///   `deep_upvalues`   — additionally forced when the result is deep-
///       forced by the caller. Covers structure-building chunks
///       (attr-sets, lists) whose body itself forces nothing but whose
///       contained values get forced if the result is walked.
pub const ChunkStrictness = struct {
    /// Upvalue slot N (0..63) is unconditionally forced when the chunk
    /// runs. Slots ≥ 64 are dropped silently — coverage degrades for
    /// chunks with many captures, which are rare.
    forced_upvalues: u64 = 0,
    /// Upvalue slot N is additionally forced when the result is
    /// recursively deep-forced. Superset of `forced_upvalues`.
    deep_upvalues: u64 = 0,
};

/// Compile-time classification of trivial chunk shapes. When a
/// chunk's entire body is a single value-load followed by ret, we can
/// short-circuit `thunk` and skip creating a thunk altogether
/// — just push the inlined value at the caller. Cuts a heap alloc, a
/// future force, a frame push/pop, and 2 dispatches per occurrence.
pub const TrivialBody = union(enum) {
    /// Not a trivial shape — full thunk creation required.
    none,
    /// Body is `up_get_ret upvalue[N]` (or `up_get N; ret`).
    /// At thunk we know upvalue N's value from the descriptor,
    /// so we push that value directly instead of allocating a thunk.
    identity_upvalue: u16,
    /// Body is `closure CL, 0; ret; halt` (or `closure_w`). The
    /// chunk wraps a zero-upvalue closure. At thunk we
    /// allocate the closure directly, skipping the thunk wrapper.
    /// Each invocation still gets a fresh closure ObjectId — same as
    /// running the body — but the thunk alloc + future force vanish.
    closure_zero: ChunkId,
    /// Body is `closure_cap CL, K, descriptors; ret; halt` with
    /// K >= 1 and every inner descriptor of kind=upvalue (which is
    /// guaranteed since thunk bodies have local_count == 0). At
    /// `thunk`, the closure's upvalue values can be resolved
    /// directly: inner_upvalue[i] = outer_descriptors[inner_idx[i]]
    /// evaluated against the outer frame. We compose the two
    /// descriptor layers and build the closure in place, skipping
    /// thunk creation entirely.
    closure_captures: ClosureCaptures,
    /// Body is `push_builtins; ret; halt` — the binding aliases the
    /// evaluator's builtins attrset. At thunk we push
    /// `vm.builtins` directly. Common via `with builtins;` blocks and
    /// `let lib = import ...; in ...` patterns where lib transitively
    /// embeds `builtins`.
    builtins,
    /// Body returns a compile-time-known `Value` — `push_const_ret #idx`
    /// (the constant is copied out of the pool at classify time, so the
    /// short-circuit never touches the Chunk) or one of
    /// `push_null|push_true|push_false; ret; halt`. Saves one heap
    /// alloc + one thunk force per binding.
    literal: Value,
    /// Body is `up_get_attr U N; ret; halt` (7 bytes) — the
    /// pervasive `someUpvalue.attr` thunk (`config.foo`, `lib.bar`,
    /// attrset-pattern param lookups). At thunk creation we resolve
    /// upvalue `U` from the descriptor and build a frameless
    /// `attr_access` thunk over (base, name), so forcing skips the
    /// isolated frame + bytecode dispatch and goes straight to
    /// `getAttrValue`.
    attr_access: AttrAccessShape,
};

pub const AttrAccessShape = struct {
    upvalue_index: u16,
    name: u16,
};

pub const ClosureCaptures = struct {
    closure_chunk_id: ChunkId,
    /// Slice into the *enclosing* chunk's `code` buffer where the
    /// inner descriptors live. Stored as (offset, len) since the
    /// classifier runs before the buffer is duped into the final
    /// Chunk — we resolve to a real slice at use time via
    /// `ch.code[offset..offset+len]`.
    inner_descriptors_offset: u16,
    inner_descriptors_len: u16,
};

/// All compile-time hints the scheduler uses when deciding whether to
/// submit a thunk for parallel forcing. Stamped at chunk-builder
/// finish, never mutated at runtime.
pub const SchedulingHints = struct {
    /// True when the chunk's bytecode body is large enough that a
    /// helper finishing it ahead of demand saves more than the
    /// scheduler submit/wake overhead costs. Cached here so the
    /// thunk-creation hot path doesn't have to re-read `code.len`.
    body_is_substantial: bool = false,
    /// True when the chunk's effective body size is below
    /// `speculation_trusted_code_bytes`: its unattended speculative
    /// execution is NOT trusted (the sub-256 combinator family — small
    /// bodies whose one execution can recursively force multi-million-
    /// thunk never-demanded subgraphs). Speculative `force_thunk` tasks
    /// whose ROOT chunk carries this bit run under a hard creation
    /// budget (`Scheduler.Config.spec_band_budget`); trusted roots run
    /// unbudgeted. With the admission gate at its default
    /// (== trusted threshold) no such chunk is ever submitted, so the
    /// bit is dormant; it exists so lowering the admission gate — or a
    /// future aged-pool drain of the small-body family — cannot cascade
    /// without a creation bound.
    spec_band_small: bool = false,
    /// See ChunkStrictness.
    strictness: ChunkStrictness = .{},
    /// Trivial-shape classification — see `TrivialBody`.
    trivial: TrivialBody = .none,
    /// True for a single-parameter lambda whose body unconditionally
    /// forces its parameter (sound must-force). Lets a caller that holds
    /// this closure at a `call` site evaluate the argument eagerly
    /// instead of thunking it — the runtime-known-callee analogue of the
    /// compiler's directly-applied-lambda eager arg. Only meaningful when
    /// `local_count == 1` (one param, no extra locals).
    strict_param: bool = false,
    /// Forwarding strictness: the body is exactly `f param` for a
    /// captured function `f` at this upvalue index, so the lambda forces
    /// its parameter *iff* `f` does. The caller resolves it at the call
    /// site (it holds the closure's upvalues). `null` when not a simple
    /// forwarder.
    strict_via_upvalue: ?u16 = null,
};

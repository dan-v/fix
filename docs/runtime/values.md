# Values

*The NaN-boxed 8-byte `Value` and its Nix-C++-parity numeric semantics.*

Every runtime value is an 8-byte `extern struct { bits: u64 }`. Scalars and object references are **NaN-boxed** into the payload space of an IEEE-754 double: a `Value` is *either* a live `f64` *or* a tagged non-float, discriminated by its top bits. Object references never store host pointers — they carry an [`ObjectId`](heap.md) or [`InternId`](interning.md), keeping values position-independent and copyable by value.

## Bit layout

```
bits[63:51] == 0x1FFF (sign=1, exp=0x7FF, quiet=1)  →  tagged
otherwise                                           →  regular IEEE double
tagged:
  bits[50:48]  primary tag   (3 bits, 8 variants)
  bits[47:0]   payload       (48 bits: InternId / ObjectId / inline int / value)
primary tag misc (7) is refined:
  bits[47:44]  sub-tag       (4 bits)
  bits[43:0]   sub-payload   (44 bits)
```

The tagged prefix is sign=1 with the full exponent and the quiet-NaN bit set (`QNAN_PREFIX = 0xFFF8_0000_0000_0000`). `isTagged` splits on it with a single load + AND + CMP against `QNAN_PREFIX_MASK` (== `QNAN_PREFIX`, the top 13 bits): `(bits & QNAN_PREFIX_MASK) == QNAN_PREFIX`. `isFloat` is its negation. Each per-kind predicate (`isInt`, `isString`, …) is the same shape one field wider — mask the top 16 bits (`HIGH16_MASK = 0xFFFF_0000_0000_0000`), compare against `QNAN_PREFIX | (tag << 48)`; the misc sub-tag predicates additionally match bits 47:44.

**Primary tags** (bits 50:48): `int=0`, `string=1`, `path=2`, `list=3`, `attrs=4`, `thunk=5`, `closure=6`, `misc=7`.

**Misc sub-tags** (bits 47:44): `builtin_closure=0`, `string_context=1`, `builtin=2`, `null=3`, `bool_false=4`, `bool_true=5`, `boxed_int=6`, `partial_app=7`.

## Value kinds

`ValueType` (the surface of `kind()`) enumerates: `null`, `bool_false`, `bool_true`, `int`, `float`, `string` (InternId), `path` (InternId), `list`, `attrs`, `closure`, `thunk`, `builtin` (u16 id), `builtin_closure`, `string_context`, `boxed_int`, `partial_app`. Booleans are two distinct sub-tag slots — `isBool` checks both; `asBool` tests the `true` slot. `null`, `bool_false`, `bool_true`, and `builtin` are pure immediates (no heap object). All ref kinds index the [object heap](heap.md); `string`/`path` index the [intern table](interning.md).

`partial_app` is the under-saturated result of applying an uncurried (arity>1) closure — it presents as a function (`typeOf → "lambda"`, callable) and its payload is an ObjectId into a `partial_app` heap slot.

## Integers: inline i48 vs boxed i64

The int payload is the full 48 bits (sign bit included), holding sign-extended values in `[-2^47, 2^47-1]`. `asInt` sign-extends bit 47. Any i64 **outside** that range is held in a heap `boxed_int` slot and surfaced as the `boxed_int` kind.

Callers stay encoding-agnostic via `int.zig`:
- `make(heap, v)` — inline if it fits, else `addBoxedInt`.
- `get(v, heap)` — inline read (branch-free) or one heap deref.
- `isAnyInt(v)` — either encoding.

Direct `Value.int(v)` asserts the i48 bound (debug); it is only for values known in range. **Never** branch on `isInt` alone where a boxed integer is possible — use `isAnyInt`.

## Canonical-NaN scrub (invariant)

Arithmetic can produce NaNs whose bit pattern lands anywhere in qNaN space — including patterns with sign=1 that alias our tagged prefix. `float(v)` therefore **scrubs every NaN input to one canonical positive NaN** (`0x7FF8_0000_0000_0001`, sign=0), which can never collide with tagged space (sign=1). This is load-bearing: **never assume an arbitrary NaN pattern is a float** without going through `float()`, and never hand-construct a NaN into a `Value`. Every f64 that becomes a `Value` must pass through `float()`.

## Constructors / discriminators / accessors

- Construct: `int` / `float` / `string` / `path` / `list` / `attrs` / `closure` / `thunk` / `boolVal` / `null_val` / `builtin` / `builtinClosure` / `contextString` / `boxedInt` / `partialApp`.
- Discriminate: `kind()` (full `ValueType`); fast predicates `isInt`/`isFloat`/`isString`/`isPath`/`isList`/`isAttrs`/`isThunk`/`isClosure`/`isBuiltin`/`isBuiltinClosure`/`isContextString`/`isBoxedInt`/`isPartialApp`/`isNull`/`isBool`.
- Access: `asInt` / `asFloat` / `asInternId` / `asObjectId` / `asBuiltinId` / `asBool`. `asInt` and `asFloat` assert their kind in debug; `asInternId`/`asObjectId`/`asBuiltinId`/`asBool` only mask the payload with no kind check, so the caller must have already discriminated.

## Identity: `idEq` / `idHash`

`idEq` compares scalars and object refs by raw `bits` (the tag is part of the pattern, so equal bits ⇒ same kind + payload). **Floats use IEEE equality** — so two canonical NaNs compare *unequal*, matching the semantics `idEq` callers rely on. `idHash` returns the raw `bits`. These are pointer-identity/reference semantics, not Nix structural `==`.

## Numerics (Nix-C++ parity)

Arithmetic lives in `numeric.zig` and matches the C++ evaluator exactly (the [correctness oracle](../invariants.md)):

- **Checked integer overflow.** `add`/`sub`/`mul` use Zig's `*WithOverflow` and raise `error.IntegerOverflow` on wrap — never silent two's-complement. `negate` routes through `checkedSub(0, v)` so `-i64_min` raises.
- **Int/float promotion.** If both operands are any-int → checked integer path (result boxed if needed). If either is float → both promote to `f64` (`toFloat`) and the op is IEEE. `toFloat` accepts int/boxed_int/float; anything else is `error.TypeError`.
- **Division.** Integer `/0` raises `error.DivisionByZero`. The `i64_min / -1` overflow (mathematically `2^63`) raises `error.IntegerOverflow` instead of hitting Zig UB. Float `/0` **also raises** `error.DivisionByZero` — Nix does *not* yield IEEE ±Inf.
- **`floatToI64Safely`** (backs `floor`/`ceil` on floats): NaN/±Inf → `error.NumericConversion`; a float `≥ 2^63` or `< -2^63` **saturates to `i64_min`**, mirroring x86 `cvttsd2si`'s indefinite-integer result that Nix inherits; otherwise truncates via `@intFromFloat`. Bounds are exact hex-float compares (`0x1.0p63`): upper is strictly `<`, lower is `≥` (so exactly `-2^63` truncates normally to `i64_min`). `floor`/`ceil` on an int/boxed_int are identity.
- **Bitwise** (`bitAnd`/`bitOr`/`bitXor`): integers only (`error.TypeError` otherwise); operands read via `int.get`, result boxed if it exceeds i48.

Out of scope: object layouts → [heap.md](heap.md); thunk states → [thunks.md](thunks.md); string context → [derivation/context.md](../derivation/context.md).

Code: `src/runtime/value.zig`

# Derivation Hashing

*The pipeline that turns a `Drv` into store paths, and the byte-identity oracle that makes it correct.*

## Why this is the hot path

Store-path computation is **the** correctness oracle for this evaluator: every `.drv` and every output path must be **byte-identical** to what `nix-instantiate` produces. It is also a serial [critical-path cost](../perf/model.md): every input-addressed derivation is serialized to ATerm three times (masked hash-modulo, unmasked hash-modulo, `.drv` text — see the three-serialization table in step 5), and that serialization runs on the drv-hashing chain. Constant-factor wins in ATerm string-building therefore transfer to high-worker wall time (below).

## The pipeline

A store path is always the same shape — a nixBase32 digest of a **fingerprint** string, prefixed by the store dir and suffixed by a name:

```
storePathFromInnerDigest(ty, inner_digest, name):
  fingerprint = "{ty}:sha256:{inner_digest}:{store_dir}:{name}"
  hash        = nixBase32( compressDigest( sha256(fingerprint) ) )   // 32 chars
  path        = "{store_dir}/{hash}-{name}"                          // /nix/store/<hash>-<name>
```

Everything below is a matter of **which `ty`** and **which `inner_digest`** feed this formula, and what **`name`** is used (`out` → the bare drv name; any other output → `{name}-{output}`).

`computePaths(drv, resolver)` runs the stages in order:

1. **Fixed-output paths** — for the (single) output with a set `hash_algo`.
2. **Input-addressed output paths** — one *masked* hash-modulo (`mask_outputs=true`) for all outputs, then a path per output.
3. **Back-patch** each output's `env` entry to its computed path.
4. **`.drv` text path** — serialize the *actual* (unmasked, inputs-unresolved) `Drv` and text-hash it.
5. **Dependency hash-modulo** — an *unmasked* hash-modulo (`mask_outputs=false`) recorded in the derivation `Registry` for consumers to resolve against. The realization-owned `RealizationStore` hosts that registry while an evaluation is running.

The input-set resolution (`hashModuloInputs` — one resolver lookup + hash-dup + merge per input drv) is a pure function of `input_drvs` and the resolver, so `computePaths` runs it **once** and feeds the same resolved inputs to both the masked (step 2) and unmasked (step 5) hashes.

### 1. ATerm serialization

The `Drv` is rendered to Nix's ATerm textual form:

```
Derive([outputs],[inputs],[srcs],system,builder,[args],[env])

  output = (name, path, hash_algo, hash)     // path="" when masked (see hash-modulo)
  input  = (drv_path, [output_names])
  env    = (name, value)                     // value="" when masked & name is an output
```

Invariants baked in:

- **Canonical sort** of *everything* with a defined order — outputs by name, inputs by drv path, input output-name lists, srcs, and env by name — all lexicographic (byte-wise).
- **String escaping** is applied to only four fields: `builder`, each `args` element, and each `env` entry's name and value are quoted **and** escaped (`"` `\` `\n` `\r` `\t` → backslash escapes). Everything else — the output tuple fields (`name`, `path`, `hash_algo`, `hash`), input drv paths, src and output-name lists, and `system` — is quoted but **not** escaped, since those are known store-path / identifier shaped. Matching Nix's exact escaped-field set is load-bearing.

**Pre-sized buffer + escape-free bulk copy.** The output buffer is pre-sized from the dominant content (a 256-byte base, plus each env entry's name+value+8 and each input path+16) to avoid grow-and-copy reallocs; and quoted-string emission (`appendString`) bulk-copies each maximal escape-free run with one `appendSlice` rather than appending byte-by-byte. Env values (build scripts, dependency lists) are large and almost entirely escape-free, so the common case is one copy per value. Because ATerm building runs on the serial drv-hashing chain, this transfers to high-worker wall time.

### 2. hashModulo / hashModuloInputs (input-addressed hashing)

The hash-modulo is a single content hash summarizing a derivation's *inputs* (not its output paths). Two cases:

**Fixed-output** derivation (`isFixedOutput`: exactly one output with a `hash_algo`): the hash is over a flat fingerprint, no ATerm, no input resolution:

```
sha256Hex( "fixed:out:{hash_algo}:{hash}:{output_path}" )
```

Returned as a per-output hash (`.outputs`).

**Input-addressed** derivation: resolve every input drv to *its* hash-modulo, substitute those resolved hashes for the input drv paths, serialize the ATerm (masked or not, per the caller), sha256 it:

- `hashModuloInputs` walks `input_drvs`; for each, `resolver.resolvePath(input.path)` returns the input's recorded hash-modulo (built earlier and stored in the derivation `Registry`).
  - Resolved to a single **drv** hash → that hash stands in for the path; the input's requested output-names are carried through, **merged by path** (union of output-name sets if the same path appears twice).
  - Resolved to **per-output** hashes → each requested output name is mapped to its output's hash, keyed under output name `"out"`, then merged by path as above.
- The resulting substituted input list feeds `toATerm(mask_outputs, actual_inputs=...)` with input paths replaced by resolved hashes (and, under `mask_outputs=true`, output `path` fields and output-named `env` values blanked). `sha256Hex` of that ATerm is the modulo digest — a `HashModulo` with the `.drv` union tag (as opposed to the per-output `.outputs` tag of the fixed-output case).
- Missing input → `error.UnknownInputDerivation`; missing requested output → `error.UnknownDerivationOutput`.

`computePaths` renders two hashes from the one resolved input set: the `mask_outputs=true` hash derives this derivation's own output paths (its output paths aren't known yet, so they must be masked out), and the `mask_outputs=false` hash is **recorded per drv path** in the store as this derivation's dependency hash — the value a *consumer's* `hashModuloInputs` gets back when it resolves this drv as an input. This mirrors Nix: output paths come from the masked modulo, but inputs substitute the **unmasked** modulo of their dependencies.

### 3. Input-addressed output path

Per output, from the derivation's masked hash-modulo:

```
inputAddressedOutputPath(name, output, hash_modulo):
  ty = "output:{output}"
  storePathFromInnerDigest(ty, hash_modulo, outputPathName(name, output))
```

### 4. Fixed-output path

```
fixedOutputPath(name, output, hash_algo, hash):
  if hash_algo starts with "r:":        // recursive / NAR
      storePathFromInnerDigest("source", hash, outputName)
  else:                                 // flat
      inner  = "fixed:out:{hash_algo}:{hash}:"
      digest = sha256Hex(inner)
      storePathFromInnerDigest("output:out", digest, outputName)
```

### 5. `.drv` (text) path — distinct from output-path hashing

The `.drv` store path uses **text** hashing over the *actual* (unmasked) ATerm — real output paths, real input drv paths, no mask:

```
text     = toATerm(drv, mask_outputs=false, actual_inputs=null)
refs     = unique(input_drvs paths ++ input_srcs)          // sorted before use
textPath(name=".drv name", text, refs):
  digest = sha256Hex(text)
  ty     = "text" + (":" + ref for each sorted ref)        // refs appended to the type tag
  storePathFromInnerDigest(ty, digest, name)               // name = "{drv_name}.drv"
```

So a `Drv` is rendered to ATerm in **three ways**, differing along two independent axes — whether outputs are *masked* (output `path` fields and output-named `env` values blanked) and whether input drv paths are *resolved* (replaced by their recorded hash-modulo) or left concrete:

| Serialization | Masked outputs | Inputs | Used for |
|---|---|---|---|
| Output hash-modulo | yes | resolved | deriving this drv's output paths |
| Dependency hash-modulo | no | resolved | recorded in the store; what consumers substitute for this drv |
| `.drv` text | no | concrete paths | the `.drv` store path (refs folded into `ty`) |

Masking blanks output env values *only* under `mask_outputs=true`; the dependency hash-modulo (`mask_outputs=false`) keeps real output paths and real env values. The dependency and text serializations therefore differ purely in whether inputs are resolved hashes or raw drv paths.

### nixBase32 encoding

Store-path hashes are 32-character nixBase32, **not** standard base32:

- **Compress**: XOR-fold the 32-byte sha256 into 20 bytes (`compressed[i % 20] ^= digest[i]`).
- **Encode**: 5-bit radix over the alphabet `"0123456789abcdfghijklmnpqrsvwxyz"` (note: no `e`, `o`, `t`, `u` — Nix's set), emitting **bit-swapped**, i.e. output char *n* reads bits low-to-high and is placed at `len - 1 - n` (LSB→MSB). 20 bytes → 32 chars.

This store-path encoder (`hash_codec.zig`) is distinct from the flat lowercase-hex encoder `sha256Hex`. It is also separate from the base-32 encoder behind the hash builtins (`hashBytesNixBase32` in `src/runtime/hash.zig`): that one shares the same 32-char alphabet and bit-swapped emission but encodes the **full** digest (`(len*8+4)/5` chars, for md5/sha1/sha256/sha512) with no 32→20 XOR fold — the fold is specific to store-path hashes, which always compress to 20 bytes → 32 chars.

### NAR hashing

Used for `r:` fixed-output (recursive) and for **source paths** (a plain path referenced by a derivation, e.g. `./foo` copied to the store). `hashPath` walks the filesystem tree and emits Nix's minimal NAR:

- `"nix-archive-1"` magic, then per node: `type` = `regular` (+ `executable` marker) | `directory` | `symlink`, with `contents` / recursive `entry (name, node)` (dir entries **sorted by name**) / `target`.
- Every token is length-prefixed (little-endian u64) and **8-byte zero-padded**.
- sha256 of the NAR bytes → hex. A source path becomes `sourcePath(name, nar_hex)` = `storePathFromInnerDigest("source", nar_hex, name)`. `hashPath` walks unfiltered; `hashPathFiltered` takes an optional `Filter` whose `accept` callback drops directory entries during the walk.

### Hash-format normalization

User-supplied fixed-output hashes arrive in many encodings; `hashToBase16(expected_algo, text)` normalizes to lowercase hex:

- `algo:hash` or SRI `algo-hash` prefix → algo checked against `expected_algo`; SRI (`-`) body decoded as base64.
- Bare body: valid hex → passthrough; contains `= + /` → base64; else → **nixBase32-decode** (rejecting out-of-alphabet or malformed-length input rather than crashing).

## What must be byte-identical

Any drift here silently produces the wrong store path. The oracle enforces exact equality with Nix C++ on:

- **ATerm ordering** — lexicographic sort of outputs, inputs, input output-name lists, srcs, and env (`args` keep source order); the exact `Derive(...)` field layout.
- **String escaping** — only `"` `\` `\n` `\r` `\t`, and only in `builder` / `args` / `env` name+value; every other field (including `system` and the output tuple fields) quoted-but-unescaped.
- **nixBase32** — the exact 32-char alphabet, the 32→20 XOR fold, and the bit-swapped LSB→MSB emission.
- **hashModuloInputs** — resolve each input to its recorded (unmasked) hash, substitute for the path, **merge duplicate input paths by union of output names**; keep `"out"` keying for per-output resolution.
- **Fixed-output logic** — `r:` → NAR/`source`; flat → `fixed:out:{algo}:{hash}:` fingerprint; the single-output requirement.
- **The three serializations** — masked-outputs modulo (drives output paths), unmasked modulo (recorded dependency hash), and unmasked drv-text path with concrete input paths and refs folded into `ty`.
- **Sorted refs** before the text-path `ty` is built.

For value-shape and interned string handling see [runtime values](../runtime/values.md).

Code: `src/store/derivation/`

# Derivation Hashing

*The pipeline that turns a `Drv` into store paths, and the byte-identity oracle that makes it correct.*

## Why this is the hot path

Store-path computation is **the** correctness oracle for this evaluator: every `.drv` and every output path must be **byte-identical** to what `nix-instantiate` produces. It is also a top serial [critical-path cost](../perf/model.md) — evaluating the NixOS toplevel hashes ~477 distinct derivations, each requiring 3 ATerm serializations, and `main` does most of that work itself on the serial chain. Constant-factor wins in ATerm string-building therefore transfer straight to high-worker wall time (below).

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
2. **Input-addressed output paths** — one hash-modulo for all outputs, then a path per output.
3. **Back-patch** each output's `env` entry to its computed path.
4. **`.drv` text path** — serialize the *actual* (unmasked) `Drv` and text-hash it.
5. **Dependency hash-modulo** — recorded for consumers to resolve against.

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
- **String escaping** inside quoted fields: `"` `\` `\n` `\r` `\t` are backslash-escaped. `builder`, `args`, and `env` name/value are quoted+escaped; output/input path fields and src/output-name lists are quoted but **not** escaped (they are known store-path shaped).

**Pre-sized-buffer + escape-free bulk-copy optimization** (measurably transfers to high worker counts): the output buffer is pre-sized from the dominant content (env value + input-path lengths) to avoid grow-and-copy reallocs; and quoted-string emission **bulk-copies maximal escape-free runs** (`appendSlice`) instead of appending byte-by-byte. Env values (build scripts, dependency lists) are large and almost entirely escape-free, so this is ~one copy per value. Because ATerm building runs on the serial drv-hashing chain, this is a real high-worker win, not just a w=1 micro-opt.

### 2. hashModulo / hashModuloInputs (input-addressed hashing)

The hash-modulo is a single content hash summarizing a derivation's *inputs* (not its output paths). Two cases:

**Fixed-output** derivation (`isFixedOutput`: exactly one output with a `hash_algo`): the hash is over a flat fingerprint, no ATerm, no input resolution:

```
sha256_hex( "fixed:out:{hash_algo}:{hash}:{output_path}" )
```

Returned as a per-output hash (`.outputs`).

**Input-addressed** derivation: resolve every input drv to *its* hash-modulo, substitute those resolved hashes for the input drv paths (the **mask**), serialize the masked ATerm, sha256 it:

- `hashModuloInputs` walks `input_drvs`; for each, `resolver.resolvePath(input.path)` returns the input's recorded hash-modulo (built earlier and stored in the [`DerivationStore`](./model.md)).
  - Resolved to a single **drv** hash → that hash stands in for the path; the input's requested output-names are carried through, **merged by path** (union of output-name sets if the same path appears twice).
  - Resolved to **per-output** hashes → each requested output name is mapped to its output's hash, keyed under output name `"out"`, then merged by path as above.
- The resulting substituted input list feeds `toATerm(mask_outputs=true, actual_inputs=...)`: output `path` fields blank, output-named `env` values blank, input paths replaced by resolved hashes. `sha256_hex` of that ATerm is the derivation's hash (`.drv`).
- Missing input → `error.UnknownInputDerivation`; missing requested output → `error.UnknownDerivationOutput`.

`computePaths` calls this once with `mask_outputs=true` to derive output paths; the resulting hash is **cached per drv path** (via the store record) so consumers resolve it without recomputation.

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
      digest = sha256_hex(inner)
      storePathFromInnerDigest("output:out", digest, outputName)
```

### 5. `.drv` (text) path — distinct from output-path hashing

The `.drv` store path uses **text** hashing over the *actual* (unmasked) ATerm — real output paths, real input drv paths, no mask:

```
text     = toATerm(drv, mask_outputs=false, actual_inputs=null)
refs     = unique(input_drvs paths ++ input_srcs)          // sorted before use
textPath(name=".drv name", text, refs):
  digest = sha256_hex(text)
  ty     = "text" + (":" + ref for each sorted ref)        // refs appended to the type tag
  storePathFromInnerDigest(ty, digest, name)               // name = "{drv_name}.drv"
```

So the **two serializations differ**: the hash-modulo masks output paths and substitutes resolved input hashes; the drv-text hash uses concrete paths and folds the dependency set into the `ty` tag. A third **dependency-hash** variant (`hashModulo(mask_outputs=false)`) keeps output paths but blanks the `env` values named after outputs — recorded in the store for consumers.

### nixBase32 encoding

Store-path hashes are 32-character nixBase32, **not** standard base32:

- **Compress**: XOR-fold the 32-byte sha256 into 20 bytes (`compressed[i % 20] ^= digest[i]`).
- **Encode**: 5-bit radix over the alphabet `"0123456789abcdfghijklmnpqrsvwxyz"` (note: no `e`, `o`, `t`, `u` — Nix's set), emitting **bit-swapped**, i.e. output char *n* reads bits low-to-high and is placed at `len - 1 - n` (LSB→MSB). 20 bytes → 32 chars.

The Nix-base32 encoder is separate from the flat-hex encoder used for `sha256_hex` (lowercase hex). The base32 encoder is also used directly by `hashBytesNixBase32` for hash builtins.

### NAR hashing

Used for `r:` fixed-output (recursive) and for **source paths** (a plain path referenced by a derivation, e.g. `./foo` copied to the store). `hashPath` walks the filesystem tree and emits Nix's minimal NAR:

- `"nix-archive-1"` magic, then per node: `type` = `regular` (+ `executable` marker) | `directory` | `symlink`, with `contents` / recursive `entry (name, node)` (dir entries **sorted by name**) / `target`.
- Every token is length-prefixed (little-endian u64) and **8-byte zero-padded**.
- sha256 of the NAR bytes → hex. A source path becomes `sourcePath(name, nar_hex)` = `storePathFromInnerDigest("source", nar_hex, name)`. An optional filter (`filterSource`) can drop entries during the walk.

### Hash-format normalization

User-supplied fixed-output hashes arrive in many encodings; `hashToBase16(expected_algo, text)` normalizes to lowercase hex:

- `algo:hash` or SRI `algo-hash` prefix → algo checked against `expected_algo`; SRI (`-`) body decoded as base64.
- Bare body: valid hex → passthrough; contains `= + /` → base64; else → **nixBase32-decode** (rejecting out-of-alphabet or malformed-length input rather than crashing).

## What must be byte-identical

Any drift here silently produces the wrong store path. The oracle enforces exact equality with Nix C++ on:

- **ATerm ordering** — lexicographic sort of outputs, inputs, input output-name lists, srcs, and env; the exact `Derive(...)` field layout.
- **String escaping** — only `"` `\` `\n` `\r` `\t`, only in the quoted (escaped) fields; store-path-shaped fields quoted-but-unescaped.
- **nixBase32** — the exact 32-char alphabet, the 32→20 XOR fold, and the bit-swapped LSB→MSB emission.
- **hashModuloInputs** — resolve each input to its recorded hash, substitute for the path (the mask), **merge duplicate input paths by union of output names**; keep `"out"` keying for per-output resolution.
- **Fixed-output logic** — `r:` → NAR/`source`; flat → `fixed:out:{algo}:{hash}:` fingerprint; the single-output requirement.
- **The two distinct serializations** — masked-inputs hash-modulo vs unmasked drv-text path (refs folded into `ty`), plus the dependency-hash variant that blanks output-named env values.
- **Sorted refs** before the text-path `ty` is built.

For value-shape and interned string handling see [runtime values](../runtime/values.md).

Code: `src/derivation/`

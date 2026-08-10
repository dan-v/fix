//! Grisu2 float-to-shortest-decimal, a faithful port of nlohmann/json's
//! `to_chars.hpp` (MIT). Nix serializes floats through nlohmann, whose Grisu2 is
//! usually the shortest round-tripping decimal but occasionally emits one extra
//! digit (Grisu2 is not always optimal, unlike Ryu). Zig's `{d}`/`{e}` use Ryu,
//! so the two disagree on ~0.6% of doubles — enough to change a generated JSON
//! file's bytes and every drvPath built from it. To match Nix byte-for-byte we
//! reproduce Grisu2 exactly rather than "a shortest decimal".
//!
//! Ported line-for-line from nlohmann::detail::dtoa_impl so the digit generation
//! and rounding match; validated differentially against the nlohmann oracle over
//! tens of millions of random doubles (see the tests below and tools/).
//! The upstream copyright and MIT license are retained in
//! `LICENSES/nlohmann-json-MIT.txt`.

const std = @import("std");

const DiyFp = struct {
    f: u64 = 0,
    e: i32 = 0,

    fn sub(x: DiyFp, y: DiyFp) DiyFp {
        std.debug.assert(x.e == y.e and x.f >= y.f);
        return .{ .f = x.f - y.f, .e = x.e };
    }

    fn mul(x: DiyFp, y: DiyFp) DiyFp {
        const m: u64 = 0xFFFFFFFF;
        const u_lo = x.f & m;
        const u_hi = x.f >> 32;
        const v_lo = y.f & m;
        const v_hi = y.f >> 32;
        const p0 = u_lo * v_lo;
        const p1 = u_lo * v_hi;
        const p2 = u_hi * v_lo;
        const p3 = u_hi * v_hi;
        const p0_hi = p0 >> 32;
        const p1_lo = p1 & m;
        const p1_hi = p1 >> 32;
        const p2_lo = p2 & m;
        const p2_hi = p2 >> 32;
        var q = p0_hi + p1_lo + p2_lo;
        q += @as(u64, 1) << (64 - 32 - 1); // round, ties up
        const h = p3 + p2_hi + p1_hi + (q >> 32);
        return .{ .f = h, .e = x.e + y.e + 64 };
    }

    fn normalize(x: DiyFp) DiyFp {
        var r = x;
        while ((r.f >> 63) == 0) {
            r.f <<= 1;
            r.e -= 1;
        }
        return r;
    }

    fn normalizeTo(x: DiyFp, target_exponent: i32) DiyFp {
        const delta: u6 = @intCast(x.e - target_exponent);
        return .{ .f = x.f << delta, .e = target_exponent };
    }
};

const Boundaries = struct { w: DiyFp, minus: DiyFp, plus: DiyFp };

fn computeBoundaries(value: f64) Boundaries {
    // double: p=53 (with hidden bit), bias per nlohmann's kBias.
    const kPrecision: i32 = 53;
    const kBias: i32 = 1024 - 1 + (kPrecision - 1); // max_exponent-1 + (p-1) = 1075
    const kMinExp: i32 = 1 - kBias;
    const kHiddenBit: u64 = @as(u64, 1) << (kPrecision - 1);

    const bits: u64 = @bitCast(value);
    const biased_e: u64 = bits >> (kPrecision - 1);
    const frac: u64 = bits & (kHiddenBit - 1);

    const v: DiyFp = if (biased_e == 0)
        .{ .f = frac, .e = kMinExp }
    else
        .{ .f = frac + kHiddenBit, .e = @as(i32, @intCast(biased_e)) - kBias };

    const lower_boundary_is_closer = (frac == 0 and biased_e > 1);
    const m_plus: DiyFp = .{ .f = (2 * v.f) + 1, .e = v.e - 1 };
    const m_minus: DiyFp = if (lower_boundary_is_closer)
        .{ .f = (4 * v.f) - 1, .e = v.e - 2 }
    else
        .{ .f = (2 * v.f) - 1, .e = v.e - 1 };

    const w_plus = DiyFp.normalize(m_plus);
    const w_minus = DiyFp.normalizeTo(m_minus, w_plus.e);
    return .{ .w = DiyFp.normalize(v), .minus = w_minus, .plus = w_plus };
}

const kAlpha: i32 = -60;

const CachedPower = struct { f: u64, e: i32, k: i32 };

fn getCachedPowerForBinaryExponent(e: i32) CachedPower {
    const kCachedPowers = [_]CachedPower{
        .{ .f = 0xAB70FE17C79AC6CA, .e = -1060, .k = -300 }, .{ .f = 0xFF77B1FCBEBCDC4F, .e = -1034, .k = -292 },
        .{ .f = 0xBE5691EF416BD60C, .e = -1007, .k = -284 }, .{ .f = 0x8DD01FAD907FFC3C, .e = -980, .k = -276 },
        .{ .f = 0xD3515C2831559A83, .e = -954, .k = -268 },  .{ .f = 0x9D71AC8FADA6C9B5, .e = -927, .k = -260 },
        .{ .f = 0xEA9C227723EE8BCB, .e = -901, .k = -252 },  .{ .f = 0xAECC49914078536D, .e = -874, .k = -244 },
        .{ .f = 0x823C12795DB6CE57, .e = -847, .k = -236 },  .{ .f = 0xC21094364DFB5637, .e = -821, .k = -228 },
        .{ .f = 0x9096EA6F3848984F, .e = -794, .k = -220 },  .{ .f = 0xD77485CB25823AC7, .e = -768, .k = -212 },
        .{ .f = 0xA086CFCD97BF97F4, .e = -741, .k = -204 },  .{ .f = 0xEF340A98172AACE5, .e = -715, .k = -196 },
        .{ .f = 0xB23867FB2A35B28E, .e = -688, .k = -188 },  .{ .f = 0x84C8D4DFD2C63F3B, .e = -661, .k = -180 },
        .{ .f = 0xC5DD44271AD3CDBA, .e = -635, .k = -172 },  .{ .f = 0x936B9FCEBB25C996, .e = -608, .k = -164 },
        .{ .f = 0xDBAC6C247D62A584, .e = -582, .k = -156 },  .{ .f = 0xA3AB66580D5FDAF6, .e = -555, .k = -148 },
        .{ .f = 0xF3E2F893DEC3F126, .e = -529, .k = -140 },  .{ .f = 0xB5B5ADA8AAFF80B8, .e = -502, .k = -132 },
        .{ .f = 0x87625F056C7C4A8B, .e = -475, .k = -124 },  .{ .f = 0xC9BCFF6034C13053, .e = -449, .k = -116 },
        .{ .f = 0x964E858C91BA2655, .e = -422, .k = -108 },  .{ .f = 0xDFF9772470297EBD, .e = -396, .k = -100 },
        .{ .f = 0xA6DFBD9FB8E5B88F, .e = -369, .k = -92 },   .{ .f = 0xF8A95FCF88747D94, .e = -343, .k = -84 },
        .{ .f = 0xB94470938FA89BCF, .e = -316, .k = -76 },   .{ .f = 0x8A08F0F8BF0F156B, .e = -289, .k = -68 },
        .{ .f = 0xCDB02555653131B6, .e = -263, .k = -60 },   .{ .f = 0x993FE2C6D07B7FAC, .e = -236, .k = -52 },
        .{ .f = 0xE45C10C42A2B3B06, .e = -210, .k = -44 },   .{ .f = 0xAA242499697392D3, .e = -183, .k = -36 },
        .{ .f = 0xFD87B5F28300CA0E, .e = -157, .k = -28 },   .{ .f = 0xBCE5086492111AEB, .e = -130, .k = -20 },
        .{ .f = 0x8CBCCC096F5088CC, .e = -103, .k = -12 },   .{ .f = 0xD1B71758E219652C, .e = -77, .k = -4 },
        .{ .f = 0x9C40000000000000, .e = -50, .k = 4 },      .{ .f = 0xE8D4A51000000000, .e = -24, .k = 12 },
        .{ .f = 0xAD78EBC5AC620000, .e = 3, .k = 20 },       .{ .f = 0x813F3978F8940984, .e = 30, .k = 28 },
        .{ .f = 0xC097CE7BC90715B3, .e = 56, .k = 36 },      .{ .f = 0x8F7E32CE7BEA5C70, .e = 83, .k = 44 },
        .{ .f = 0xD5D238A4ABE98068, .e = 109, .k = 52 },     .{ .f = 0x9F4F2726179A2245, .e = 136, .k = 60 },
        .{ .f = 0xED63A231D4C4FB27, .e = 162, .k = 68 },     .{ .f = 0xB0DE65388CC8ADA8, .e = 189, .k = 76 },
        .{ .f = 0x83C7088E1AAB65DB, .e = 216, .k = 84 },     .{ .f = 0xC45D1DF942711D9A, .e = 242, .k = 92 },
        .{ .f = 0x924D692CA61BE758, .e = 269, .k = 100 },    .{ .f = 0xDA01EE641A708DEA, .e = 295, .k = 108 },
        .{ .f = 0xA26DA3999AEF774A, .e = 322, .k = 116 },    .{ .f = 0xF209787BB47D6B85, .e = 348, .k = 124 },
        .{ .f = 0xB454E4A179DD1877, .e = 375, .k = 132 },    .{ .f = 0x865B86925B9BC5C2, .e = 402, .k = 140 },
        .{ .f = 0xC83553C5C8965D3D, .e = 428, .k = 148 },    .{ .f = 0x952AB45CFA97A0B3, .e = 455, .k = 156 },
        .{ .f = 0xDE469FBD99A05FE3, .e = 481, .k = 164 },    .{ .f = 0xA59BC234DB398C25, .e = 508, .k = 172 },
        .{ .f = 0xF6C69A72A3989F5C, .e = 534, .k = 180 },    .{ .f = 0xB7DCBF5354E9BECE, .e = 561, .k = 188 },
        .{ .f = 0x88FCF317F22241E2, .e = 588, .k = 196 },    .{ .f = 0xCC20CE9BD35C78A5, .e = 614, .k = 204 },
        .{ .f = 0x98165AF37B2153DF, .e = 641, .k = 212 },    .{ .f = 0xE2A0B5DC971F303A, .e = 667, .k = 220 },
        .{ .f = 0xA8D9D1535CE3B396, .e = 694, .k = 228 },    .{ .f = 0xFB9B7CD9A4A7443C, .e = 720, .k = 236 },
        .{ .f = 0xBB764C4CA7A44410, .e = 747, .k = 244 },    .{ .f = 0x8BAB8EEFB6409C1A, .e = 774, .k = 252 },
        .{ .f = 0xD01FEF10A657842C, .e = 800, .k = 260 },    .{ .f = 0x9B10A4E5E9913129, .e = 827, .k = 268 },
        .{ .f = 0xE7109BFBA19C0C9D, .e = 853, .k = 276 },    .{ .f = 0xAC2820D9623BF429, .e = 880, .k = 284 },
        .{ .f = 0x80444B5E7AA7CF85, .e = 907, .k = 292 },    .{ .f = 0xBF21E44003ACDD2D, .e = 933, .k = 300 },
        .{ .f = 0x8E679C2F5E44FF8F, .e = 960, .k = 308 },    .{ .f = 0xD433179D9C8CB841, .e = 986, .k = 316 },
        .{ .f = 0x9E19DB92B4E31BA9, .e = 1013, .k = 324 },
    };
    const kCachedPowersMinDecExp: i32 = -300;
    const kCachedPowersDecStep: i32 = 8;

    const f = kAlpha - e - 1;
    const k = @divTrunc(f * 78913, 1 << 18) + @as(i32, if (f > 0) 1 else 0);
    const index: usize = @intCast(@divTrunc(-kCachedPowersMinDecExp + k + (kCachedPowersDecStep - 1), kCachedPowersDecStep));
    return kCachedPowers[index];
}

fn findLargestPow10(n: u32) struct { k: i32, pow10: u32 } {
    if (n >= 1000000000) return .{ .k = 10, .pow10 = 1000000000 };
    if (n >= 100000000) return .{ .k = 9, .pow10 = 100000000 };
    if (n >= 10000000) return .{ .k = 8, .pow10 = 10000000 };
    if (n >= 1000000) return .{ .k = 7, .pow10 = 1000000 };
    if (n >= 100000) return .{ .k = 6, .pow10 = 100000 };
    if (n >= 10000) return .{ .k = 5, .pow10 = 10000 };
    if (n >= 1000) return .{ .k = 4, .pow10 = 1000 };
    if (n >= 100) return .{ .k = 3, .pow10 = 100 };
    if (n >= 10) return .{ .k = 2, .pow10 = 10 };
    return .{ .k = 1, .pow10 = 1 };
}

fn grisu2Round(buf: []u8, len: usize, dist: u64, delta: u64, rest_in: u64, ten_k: u64) void {
    var rest = rest_in;
    while (rest < dist and delta - rest >= ten_k and
        (rest + ten_k < dist or dist - rest > rest + ten_k - dist))
    {
        std.debug.assert(buf[len - 1] != '0');
        buf[len - 1] -= 1;
        rest += ten_k;
    }
}

fn grisu2DigitGen(buf: []u8, length: *usize, decimal_exponent: *i32, m_minus: DiyFp, w: DiyFp, m_plus: DiyFp) void {
    var delta = DiyFp.sub(m_plus, m_minus).f;
    var dist = DiyFp.sub(m_plus, w).f;
    const neg_e: u6 = @intCast(-m_plus.e);
    const one: DiyFp = .{ .f = @as(u64, 1) << neg_e, .e = m_plus.e };

    var p1: u32 = @intCast(m_plus.f >> neg_e);
    var p2: u64 = m_plus.f & (one.f - 1);

    const found = findLargestPow10(p1);
    var n: i32 = found.k;
    var pow10: u32 = found.pow10;

    while (n > 0) {
        const d: u32 = p1 / pow10;
        const r: u32 = p1 % pow10;
        buf[length.*] = @intCast('0' + d);
        length.* += 1;
        p1 = r;
        n -= 1;
        const rest: u64 = (@as(u64, p1) << neg_e) + p2;
        if (rest <= delta) {
            decimal_exponent.* += n;
            const ten_n: u64 = @as(u64, pow10) << neg_e;
            grisu2Round(buf, length.*, dist, delta, rest, ten_n);
            return;
        }
        pow10 /= 10;
    }

    var m: i32 = 0;
    while (true) {
        p2 *= 10;
        const d: u64 = p2 >> neg_e;
        const r: u64 = p2 & (one.f - 1);
        buf[length.*] = @intCast('0' + @as(u8, @intCast(d)));
        length.* += 1;
        p2 = r;
        m += 1;
        delta *= 10;
        dist *= 10;
        if (p2 <= delta) break;
    }
    decimal_exponent.* -= m;
    const ten_m: u64 = one.f;
    grisu2Round(buf, length.*, dist, delta, p2, ten_m);
}

/// digits[0..len] and decimal_exponent such that value == digits * 10^exp.
pub const Shortest = struct {
    buf: [24]u8 = undefined,
    len: usize = 0,
    exp: i32 = 0,
    pub fn digits(self: *const Shortest) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Grisu2 shortest decimal for a finite, positive, nonzero `value`.
pub fn shortest(value: f64) Shortest {
    var out: Shortest = .{};
    const b = computeBoundaries(value);
    const cached = getCachedPowerForBinaryExponent(b.plus.e);
    const c_minus_k: DiyFp = .{ .f = cached.f, .e = cached.e };
    const w = DiyFp.mul(b.w, c_minus_k);
    const w_minus = DiyFp.mul(b.minus, c_minus_k);
    const w_plus = DiyFp.mul(b.plus, c_minus_k);
    const big_m_minus: DiyFp = .{ .f = w_minus.f + 1, .e = w_minus.e };
    const big_m_plus: DiyFp = .{ .f = w_plus.f - 1, .e = w_plus.e };
    out.exp = -cached.k;
    grisu2DigitGen(&out.buf, &out.len, &out.exp, big_m_minus, w, big_m_plus);
    return out;
}

/// Format `value` as nlohmann's `to_chars` does (Nix's JSON float form), into
/// `buf`. Handles the sign, zero, non-finite, fixed vs scientific choice, and
/// the always-`.0` / `e±NN` conventions. Returns the written slice.
pub fn format(buf: []u8, value: f64) []const u8 {
    if (std.math.isNan(value)) return "null";
    if (std.math.isInf(value)) return "null";
    if (value == 0) return if (std.math.signbit(value)) "-0.0" else "0.0";

    var i: usize = 0;
    var v = value;
    if (std.math.signbit(v)) {
        buf[0] = '-';
        i = 1;
        v = -v;
    }

    const s = shortest(v);
    const digits = s.digits();
    const k: i32 = @intCast(digits.len);
    const n: i32 = k + s.exp; // decimal point position

    // nlohmann to_chars: kMinExp = -4, kMaxExp = digits10 = 15 for double.
    const kMinExp: i32 = -4;
    const kMaxExp: i32 = 15;

    // Work in a local digit buffer, then lay out per format_buffer.
    const w = buf[i..];
    @memcpy(w[0..digits.len], digits);

    if (k <= n and n <= kMaxExp) {
        // digits[000].0
        const nn: usize = @intCast(n);
        @memset(w[@intCast(k)..nn], '0');
        w[nn] = '.';
        w[nn + 1] = '0';
        return buf[0 .. i + nn + 2];
    }
    if (0 < n and n <= kMaxExp) {
        // dig.its
        const nn: usize = @intCast(n);
        const kk: usize = @intCast(k);
        std.mem.copyBackwards(u8, w[nn + 1 .. kk + 1], w[nn..kk]);
        w[nn] = '.';
        return buf[0 .. i + kk + 1];
    }
    if (kMinExp < n and n <= 0) {
        // 0.[000]digits
        const kk: usize = @intCast(k);
        const zeros: usize = @intCast(-n);
        std.mem.copyBackwards(u8, w[2 + zeros .. 2 + zeros + kk], w[0..kk]);
        w[0] = '0';
        w[1] = '.';
        @memset(w[2 .. 2 + zeros], '0');
        return buf[0 .. i + 2 + zeros + kk];
    }
    // scientific: d.igits e±NN  (or dE±NN for a single digit)
    var end: usize = i;
    const kk: usize = @intCast(k);
    if (k == 1) {
        end = i + 1;
    } else {
        std.mem.copyBackwards(u8, w[2 .. 1 + kk], w[1..kk]);
        w[1] = '.';
        end = i + 1 + kk;
    }
    buf[end] = 'e';
    end += 1;
    end += appendExponent(buf[end..], n - 1);
    return buf[0..end];
}

fn appendExponent(buf: []u8, e_in: i32) usize {
    var e = e_in;
    var i: usize = 0;
    if (e < 0) {
        e = -e;
        buf[i] = '-';
        i += 1;
    } else {
        buf[i] = '+';
        i += 1;
    }
    const k: u32 = @intCast(e);
    if (k < 10) {
        buf[i] = '0';
        buf[i + 1] = @intCast('0' + k);
        return i + 2;
    } else if (k < 100) {
        buf[i] = @intCast('0' + (k / 10));
        buf[i + 1] = @intCast('0' + (k % 10));
        return i + 2;
    } else {
        buf[i] = @intCast('0' + (k / 100));
        buf[i + 1] = @intCast('0' + ((k / 10) % 10));
        buf[i + 2] = @intCast('0' + (k % 10));
        return i + 3;
    }
}

test "grisu2 matches the nlohmann oracle corpus" {
    // Differential corpus against nlohmann/json 3.12.0 (the version Nix
    // serializes with), one value per line across two @embedFile'd files:
    // every sampled double whose shortest-decimal digits differ from
    // Ryu-class renderers, curated edge cases, and a uniform sample.
    const hex = @embedFile("grisu2_corpus.hex");
    const exp = @embedFile("grisu2_corpus.expected");
    var hit = std.mem.tokenizeScalar(u8, hex, '\n');
    var eit = std.mem.tokenizeScalar(u8, exp, '\n');
    var buf: [64]u8 = undefined;
    var count: usize = 0;
    var mismatches: usize = 0;
    while (hit.next()) |hline| {
        const eline = eit.next() orelse break;
        const bits = try std.fmt.parseInt(u64, hline, 16);
        const v: f64 = @bitCast(bits);
        const got = format(&buf, v);
        if (!std.mem.eql(u8, got, eline)) {
            mismatches += 1;
            if (mismatches <= 10)
                std.debug.print("grisu2 mismatch: bits={s} got=[{s}] want=[{s}]\n", .{ hline, got, eline });
        }
        count += 1;
    }
    std.debug.print("grisu2 checked {d} values, {d} mismatches\n", .{ count, mismatches });
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

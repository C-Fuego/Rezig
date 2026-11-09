//! A drop-in replacement for glibc's `rand()` (TYPE_3 additive feedback
//! generator, DEG_3 = 31, SEP_3 = 3).
//!
//! cbonsai uses plain `srand()`/`rand()`, so reusing the same generator means
//! `zbonsai -s 42` grows the *same* tree as `cbonsai -s 42` (modulo terminal
//! size) instead of merely a similar one. It also avoids pulling in a
//! third-party RNG.
//!
//! Reference: glibc `stdlib/random_r.c` (`__srandom_r`, `__random_r`).
const std = @import("std");

pub const Rand = struct {
    pub const deg = 31;
    pub const sep = 3;
    /// The generator state plus one slot, like glibc's `randtbl`.
    state: [deg]i32 = @splat(0),
    fptr: usize = 0,
    rptr: usize = 0,

    pub fn init(seed_in: u64) Rand {
        var self: Rand = .{};
        self.seed(seed_in);
        return self;
    }

    fn step(self: *Rand) u31 {
        // val = *fptr += *rptr  (int32 wrapping add)
        const f = self.fptr;
        const r = self.rptr;
        self.state[f] +%= self.state[r];
        const val: u32 = @bitCast(self.state[f]);

        self.fptr += 1;
        if (self.fptr >= deg) {
            self.fptr = 0;
            self.rptr += 1;
        } else {
            self.rptr += 1;
            if (self.rptr >= deg) self.rptr = 0;
        }
        // "Chucking least random bit" - matches glibc exactly.
        return @intCast(val >> 1);
    }

    pub fn seed(self: *Rand, seed_in: u64) void {
        var x: i32 = @bitCast(@as(u32, @truncate(seed_in)));
        if (x == 0) x = 1;
        self.state[0] = x;
        var i: usize = 1;
        while (i < deg) : (i += 1) {
            // state[i] = (16807 * state[i-1]) % 2147483647, overflow-free.
            const prev = self.state[i - 1];
            const hi = @divTrunc(prev, 127773);
            const lo = @rem(prev, 127773);
            var word: i32 = 16807 *% lo -% 2836 *% hi;
            if (word < 0) word +%= 2147483647;
            self.state[i] = word;
        }
        self.fptr = sep;
        self.rptr = 0;
        // Warm-up: glibc discards 10 * DEG_3 values.
        var warm: usize = 0;
        while (warm < 10 * deg) : (warm += 1) _ = self.step();
    }

    /// glibc `rand()`: a value in [0, 2^31 - 1].
    pub fn next(self: *Rand) u31 {
        return self.step();
    }

    /// `rand() % mod`, the only way cbonsai consumes randomness.
    pub fn roll(self: *Rand, mod: u32) u32 {
        if (mod == 0) return 0;
        return @intCast(@as(u32, self.step()) % mod);
    }
};

// ---------------------------------------------------------------------------
// tests: the expected numbers come from glibc 2.44's rand()
// ---------------------------------------------------------------------------

test "matches glibc rand() for several seeds" {
    const cases = [_]struct { seed: u64, expected: [6]u32 }{
        .{ .seed = 1, .expected = .{ 383, 886, 777, 915, 793, 335 } },
        .{ .seed = 42, .expected = .{ 166, 740, 881, 241, 12, 758 } },
        .{ .seed = 1234, .expected = .{ 414, 339, 155, 67, 60, 741 } },
        .{ .seed = 2147483647, .expected = .{ 62, 300, 375, 770, 222, 725 } },
    };
    for (cases) |case| {
        var r = Rand.init(case.seed);
        for (case.expected) |want| {
            try std.testing.expectEqual(want, r.roll(1000));
        }
    }
}

test "raw values match glibc for seed 42" {
    var r = Rand.init(42);
    const expected = [_]u31{ 71876166, 708592740, 1483128881, 907283241 };
    for (expected) |want| try std.testing.expectEqual(want, r.next());
}

test "seed 0 behaves like glibc (treated as 1)" {
    var a = Rand.init(0);
    var b = Rand.init(1);
    try std.testing.expectEqual(b.next(), a.next());
}

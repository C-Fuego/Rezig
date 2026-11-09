//! textfig - the shared FIGlet/TOIlet core used by zfiglet and ztoilet.
//!
//! Public surface:
//!   textfig.font     - .flf/.tlf parsing, glyph lookup, font search, listing
//!   textfig.render   - the six smushing rules, layout modes, line breaking
//!   textfig.control  - .flc/.tlc control-file parsing and application
//!
//! The module has no third-party dependencies and does no terminal I/O: the
//! CLIs decide how a rendered line is displayed or exported.

const std = @import("std");

pub const font = @import("font.zig");
pub const render = @import("render.zig");
pub const control = @import("control.zig");

/// Test fixture shared with the CLI packages so that their tests do not need
/// to duplicate a 308-line FIGfont. It is tiny (a few KiB).
pub const fixtures = struct {
    pub const tiny_flf = @embedFile("testdata/tiny.flf");
    pub const tiny_tlf = @embedFile("testdata/tiny.tlf");
};

test {
    _ = font;
    _ = render;
    _ = control;
}

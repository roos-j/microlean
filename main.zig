const std = @import("std");

const LevelManager = @import("src/level.zig").LevelManager;

const E = @import("src/expr.zig");

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lm: *LevelManager = .create(allocator);
    const em: *E.ExprManager = .create(allocator, lm);
    std.debug.assert(em.globalStore.isOpen);

    std.debug.print("bitSizeOf ExprKind={d}\n", .{@bitSizeOf(E.ExprKind)});
    std.debug.print("sizeOf ExprKind={d}\n", .{@sizeOf(E.ExprKind)});

    // const K = enum(u3) { a0, a1, a2, a3, a4, a5 };

    const A = packed struct {
        id: u32,

        k: E.ExprKind,
        _reserved: u4,

        _reserved2: u8,

        storeId: u16
    };

    std.debug.assert(@bitSizeOf(A) == 64);

}

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
}

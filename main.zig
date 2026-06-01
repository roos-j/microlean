const std = @import("std");

const LevelManager = @import("src/level.zig").LevelManager;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mgr: LevelManager = try LevelManager.init(allocator);

    // const lvl_zero = mgr.store.get(@intCast(0));
    // std.debug.print("{s}\n", .{@tagName(std.meta.activeTag(lvl_zero))});
    // const lvl_one = mgr.store.get(@intCast(1));
    // std.debug.print("{s}\n", .{@tagName(std.meta.activeTag(lvl_one))});
    mgr.printLevel(0);
    std.debug.print("\n", .{});
    mgr.printLevel(1);
    std.debug.print("\n", .{});
    const lvl_succ = mgr.mkSucc(1);
    const lvl_max = mgr.mkMax(lvl_succ, 1);
    mgr.printLevel(lvl_max);
    std.debug.print("\n", .{});
    const lvl_test = mgr.mkMax(mgr.mkSucc(mgr.mkSucc(mgr.mkSucc(mgr.mkParam(0)))), lvl_max);
    mgr.printLevel(lvl_test);
    std.debug.print("\n", .{});

    mgr.printAllNodes();
    std.debug.assert(!mgr.equal(0, 1));
    std.debug.assert(mgr.equal(2, 2));
}

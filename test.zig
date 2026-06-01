const std = @import("std");
const LevelManager = @import("src/level.zig").LevelManager;

test "LevelTest" {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mgr: LevelManager = try LevelManager.init(allocator);

    const zero = mgr.mkZero();
    const one = mgr.mkOne();
    try std.testing.expect(zero == 0);
    try std.testing.expect(one == 1);

    const two = mgr.mkSucc(one);
    try std.testing.expect(two == mgr.mkSucc(mgr.mkSucc(zero)));
    try std.testing.expect(mgr.isExplicit(two));
    try std.testing.expect(mgr.getOffset(two) == 2);
    try std.testing.expect(mgr.getOffsetBaseKind(two) == .zero);
    try std.testing.expect(!mgr.hasParam(two));

    try std.testing.expect(mgr.nodes.items.len == 3);
    const param0 = mgr.mkParam(0);
    try std.testing.expect(param0 == 3);
    try std.testing.expect(mgr.mkParam(0) == param0);
    try std.testing.expect(mgr.nodes.items.len == 4);
    try std.testing.expect(mgr.getOffset(param0) == 0);
    try std.testing.expect(!mgr.equal(two, param0));
    try std.testing.expect(mgr.hasParam(param0));
    try std.testing.expect(mgr.mkMax(mgr.mkMax(mgr.mkParam(0), mgr.mkZero()), mgr.mkParam(0)) == param0);

    const maxzerotwo = mgr.mkMax(mgr.mkZero(), mgr.mkSucc(mgr.mkSucc(mgr.mkZero())));
    try std.testing.expect(maxzerotwo == two);
    try std.testing.expect(mgr.nodes.items.len == 4);

    const succparam0 = mgr.mkSucc(param0);
    try std.testing.expect(!mgr.isExplicit(succparam0));
    try std.testing.expect(mgr.getOffset(succparam0) == 1);
    
    const param0plustwo = mgr.mkSucc(mgr.mkSucc(mgr.mkParam(0)));
    try std.testing.expect(mgr.getOffset(param0plustwo) == 2);
    try std.testing.expect(mgr.getOffsetBase(param0plustwo) == mgr.mkParam(0));
    try std.testing.expect(!mgr.isExplicit(param0plustwo));
    try std.testing.expect(mgr.hasParam(param0plustwo));

    const three = mgr.mkSucc(two);
    try std.testing.expect(three == mgr.mkSucc(mgr.mkMax(mgr.mkOne(), mgr.mkSucc(mgr.mkOne()))));
    try std.testing.expect(!mgr.equal(mgr.mkParam(0), mgr.mkParam(1)));
    try std.testing.expect(!mgr.equal(mgr.mkSucc(param0), mgr.mkSucc(mgr.mkParam(1))));
}

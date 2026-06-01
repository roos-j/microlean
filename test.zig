const std = @import("std");
const LevelManager = @import("src/level.zig").LevelManager;
const ExprManager = @import("src/expr.zig").ExprManager;

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

test "ExprTest" {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lm: LevelManager = try LevelManager.init(allocator);
    var em: ExprManager = ExprManager.init(allocator, &lm);

    const u = lm.mkParam(0);

    const Prop = em.mkSort(0);
    const Type = em.mkSort(1);
    const Sortu = em.mkSort(u);

    try std.testing.expect(!em.hasLevelParam(Prop));
    try std.testing.expect(em.hasLevelParam(Sortu));
    try std.testing.expect(em.getKind(Type) == .sort);

    const nf = 1;
    const f = em.mkConst(nf, &.{});
    try std.testing.expect(em.getKind(f) == .cnst);
    // lam x : Sort u => x
    const e_id = em.mkLambda(nf, Sortu, em.mkBvar(0));
    try std.testing.expect(em.hasLevelParam(e_id));
    try std.testing.expect(em.getLooseBvarRange(e_id) == 0);
    try std.testing.expect(em.getKind(e_id) == .lambda);

    const e_loose = em.mkApp(f,em.mkBvar(0));
    try std.testing.expect(em.getLooseBvarRange(e_loose) == 1);

    // Type -> Prop
    const nP = 2;
    const e_tp = em.mkForallE(nP, Type, Prop);
    try std.testing.expect(em.getApproxDepth(e_tp) == 1);
    try std.testing.expect(!em.hasLevelParam(e_tp));
    try std.testing.expect(em.getLooseBvarRange(e_tp) == 0);

    const e_nonsense = em.mkForallE(nf, em.mkBvar(1), em.mkApp(em.mkConst(nP, &.{u, Prop}), e_tp));
    try std.testing.expect(em.getApproxDepth(e_nonsense) == 3);
    try std.testing.expect(em.hasLevelParam(e_nonsense));
    try std.testing.expect(em.getLooseBvarRange(e_nonsense) == 2);

    const nx = 3;
    const target_depth = 256;
    var current_depth: u32 = 1;
    var e_deep = em.mkApp(nf, nx);
    while (current_depth < target_depth) {
        try std.testing.expect(em.getApproxDepth(e_deep) == @min(current_depth, 255)); 
        e_deep = em.mkApp(nf, e_deep);
        current_depth += 1;
    }
}
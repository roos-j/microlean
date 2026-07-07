const std = @import("std");
const Buffer = @import("src/common.zig").Buffer;
const Name = @import("src/common.zig").Name;
const LevelManager = @import("src/level.zig").LevelManager;
const Expr = @import("src/expr.zig").Expr;
const ExprManager = @import("src/expr.zig").ExprManager;
const ExprStore = @import("src/expr.zig").ExprStore;
const TypeChecker = @import("src/type_checker.zig").TypeChecker;
const Environment = @import("src/environment.zig").Environment;

const Parser = @import("src/parser.zig").Parser;
const Elab = @import("src/elab.zig").Elab;

const TestCtx = @import("test.zig").TestCtx;

test "Elab.elabTerm" {
    var ctx: TestCtx = .init();
    defer ctx.deinit();
    const env = ctx.env;
    const em = ctx.em;
    const es = ctx.em.getGlobalStore();
    const lm = ctx.lm;
    
    const src = "fun x : Nat => x";
    const nx: Name = 2;
    const nNat: Name = 1;
    // axiom Nat : Sort 1
    try env.addAxiom(nNat, &.{}, es.mkSort(1));

    const p = Parser._create(std.testing.allocator, lm, src);
    defer p.destroy();

    var el: Elab = .init(std.testing.allocator, p, em, es, env);
    defer el.deinit();
    
    const term = try p.term();
    const e = try el.elabTerm(term);
    try std.testing.expect(e.isLambda());
    const node = em.getNode(e);
    try std.testing.expect(node.content.lambda.binderName == nx);
    try std.testing.expect(node.content.lambda.binderType.isConst());
    try std.testing.expect(node.content.lambda.body.isBvar());
}

test "Elab.elabDecl" {
    var ctx: TestCtx = .init();
    defer ctx.deinit();
    const env = ctx.env;
    const em = ctx.em;
    const es = ctx.em.getGlobalStore();
    const lm = ctx.lm;
    
    const src = "def id := fun x : Sort 1 => x";
    const p = Parser._create(std.testing.allocator, lm, src);
    defer p.destroy();

    var el: Elab = .init(std.testing.allocator, p, em, es, env);
    defer el.deinit();

    const cmd = try p.command();
    try std.testing.expect(cmd.kind() == .def);
    const ci = try el.elabDecl(cmd, true);
    try std.testing.expect(ci.getValue().isLambda());
    try std.testing.expect(ci.getType().isPi());
    try std.testing.expect(ci.getName() == p.getNameByIdent("id"));
    // try std.testing.expect(ci.)
}
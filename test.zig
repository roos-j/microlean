const std = @import("std");
const Buffer = @import("src/common.zig").Buffer;
const Name = @import("src/common.zig").Name;
const LevelManager = @import("src/level.zig").LevelManager;
const Expr = @import("src/expr.zig").Expr;
const ExprManager = @import("src/expr.zig").ExprManager;
const ExprStore = @import("src/expr.zig").ExprStore;
const TypeChecker = @import("src/type_checker.zig").TypeChecker;
const Environment = @import("src/environment.zig").Environment;

const TestCtx = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    lm: *LevelManager,
    em: *ExprManager,
    gs: *ExprStore,
    env: *Environment,

    pub fn init() Self {
        const allocator = std.testing.allocator;
        const lm = LevelManager.create(allocator);
        const em = ExprManager.create(allocator, lm);
        const env = Environment.create(allocator);
        return .{
            .allocator = allocator,
            .lm = lm,
            .em = em,
            .gs = em.getGlobalStore(),
            .env = env
        };
    }

    pub fn deinit(self: *Self) void {
        self.em.destroy();
        self.lm.destroy();
        self.env.destroy();
    }
};

test "LevelTest" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const mgr = ctx.lm;

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
    try std.testing.expect(@bitSizeOf(Expr) == 64);

    var ctx = TestCtx.init();
    defer ctx.deinit();
    const lm = ctx.lm;
    const em = ctx.em;
    const es = ctx.gs;

    const u = lm.mkParam(0);

    const Prop = es.mkSort(0);
    const Type = es.mkSort(1);
    const Sortu = es.mkSort(u);

    try std.testing.expect(!Prop.hasLevelParam());
    try std.testing.expect(Sortu.hasLevelParam());
    try std.testing.expect(Type.isSort());

    const nf = 1;
    const f = es.mkConst(nf, &.{});
    try std.testing.expect(f.isImmediate());
    try std.testing.expect(f.isConst());
    // lam x : Sort u => x
    const e_id = es.mkLambda(nf, Sortu, es.mkBvar(0));
    try std.testing.expect(!e_id.isImmediate());
    try std.testing.expect(e_id.hasLevelParam());
    try std.testing.expect(em.getLooseBvarRange(e_id) == 0);
    try std.testing.expect(e_id.isLambda());

    const e_loose = es.mkApp(f,es.mkBvar(0));
    try std.testing.expect(e_loose.isApp());
    try std.testing.expect(em.getLooseBvarRange(e_loose) == 1);

    // Type -> Prop
    const nP = 2;
    const e_tp = es.mkForallE(nP, Type, Prop);
    try std.testing.expect(e_tp.isPi());
    try std.testing.expect(em.getApproxDepth(e_tp) == 1);
    try std.testing.expect(!e_tp.hasLevelParam());
    try std.testing.expect(em.getLooseBvarRange(e_tp) == 0);

    const e_nonsense = es.mkForallE(nf, es.mkBvar(1), es.mkApp(es.mkConst(nP, &.{u, 0}), e_tp));
    try std.testing.expect(em.getApproxDepth(e_nonsense) == 3);
    try std.testing.expect(e_nonsense.hasLevelParam());
    try std.testing.expect(em.getLooseBvarRange(e_nonsense) == 2);

    const nx = 3;
    const x = es.mkConst(nx, &.{});
    const target_depth = 256;
    var current_depth: u32 = 1;
    var e_deep = es.mkApp(f, x);
    while (current_depth < target_depth) {
        try std.testing.expect(em.getApproxDepth(e_deep) == @min(current_depth, 255)); 
        e_deep = es.mkApp(f, e_deep);
        current_depth += 1;
    }
}

test "ExprStore" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const em = ctx.em;
    const gs = ctx.gs;

    try std.testing.expect(gs.storeId == 0);

    const e = gs.mkSort(0);
    try std.testing.expect(e.storeId() == 0);

    const store1 = em.createStore();
    try std.testing.expect(store1.storeId == 1);

    const store2 = em.createStore();
    try std.testing.expect(store2.storeId == 2);
    try std.testing.expect(store2.isOpen);
    
    const e1 = store2.mkConst(0, &.{});
    try std.testing.expect(e1.storeId() == 2);
    const e2 = store2.mkApp(e, e1);
    try std.testing.expect(e2.storeId() == 2);
    try std.testing.expect(store2.nodes.items.len == 1);
    try std.testing.expect(store2.hashMap.count() == 1);

    em.closeStore(store2.storeId);
    try std.testing.expect(!store2.isOpen);
    try std.testing.expect(store2.nodes.items.len == 0);
    try std.testing.expect(store2.hashMap.count() == 0);

    const store3 = em.createStore();
    try std.testing.expect(store3.storeId == 2);
    try std.testing.expect(store2 == store3);
    const e3 = store2.mkApp(e, e);
    try std.testing.expect(e3.storeId() == 2);
}

test "Expr.getAppArgsRev" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const s = ctx.gs;
    const f = s.mkConst(0, &.{});
    const args: [3]Expr = .{
        s.mkConst(1, &.{}),
        s.mkConst(2, &.{}),
        s.mkConst(3, &.{})
    };
    
    const e = s.mkApp(s.mkApp(s.mkApp(f, args[0]), args[1]), args[2]);
    var revargs = Buffer(Expr).init(ctx.allocator);
    defer revargs.deinit();

    const head = ctx.em.getAppArgsRev(e, &revargs);
    try std.testing.expect(head == f);
    try std.testing.expect(revargs.len() == 3);
    for (0..3) |i| {
        try std.testing.expect(revargs.get(i) == args[2-i]);
    }
}

test "ExprStore.replace" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const s = ctx.gs;
    const em = ctx.em;

    const e = s.mkApp(s.mkBvar(0), s.mkLambda(0, s.mkSort(0), s.mkBvar(1)));

    const replace_bvars = struct {
        fn call (st: anytype, sube: Expr, offset: u32) ?Expr {
            var store: *ExprStore = st;
            if (sube.isBvar()) {
                return store.mkBvar(sube.bvarId() + offset);
            } else {
                return null;
            }
        }
    }.call;
    const new_e = s.replace(s, e,  replace_bvars);

    const app_fun = em.getApp(new_e).fun;

    try std.testing.expect(app_fun.isBvar());
    try std.testing.expect(app_fun.bvarId() == 0);
    
    const app_arg = em.getApp(new_e).arg;
    try std.testing.expect(app_arg.isLambda());
    const lambda_body = em.getLambda(app_arg).body;
    try std.testing.expect(lambda_body.isBvar());
    try std.testing.expect(lambda_body.bvarId() == 2);
}

test "ExprStore.substLooseBvars" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const s = ctx.gs;
    const em = ctx.em;

    // Example 1
    // forallE a:A => #0 #1
    const e1 = s.mkForallE(0, s.mkFreeConst(1), 
        s.mkApp(s.mkBvar(0), s.mkBvar(1)));
    // Subst: [x, y]
    const x = s.mkFreeConst(2);
    const subst:[] const Expr = &.{ x, s.mkFreeConst(3) };
    const res1 = s.substLooseBvars(e1, 0, subst);
    // Expect: forallE a:A => #0 x
    try std.testing.expect(res1.isPi());
    const res1_body_app = em.getApp(em.getPi(res1).body);
    try std.testing.expect(res1_body_app.fun.bvarId() == 0);
    try std.testing.expect(res1_body_app.arg == x);
    // With start index 1, expression should not change
    try std.testing.expect(s.substLooseBvars(e1, 1, subst) == e1);

    // Example 2
    // fun a:A => fun b:B => g #2 #3 (2 loose bvars)
    const e2 = s.mkLambda(0, s.mkFreeConst(1), 
        s.mkLambda(2, s.mkFreeConst(3),
        s.mkApp(s.mkApp(s.mkFreeConst(4), s.mkBvar(2)), s.mkBvar(3)) )); 
    // Replace loose bvar by (h #0 #1)
    const subs = s.mkApp(
        s.mkApp(s.mkFreeConst(5), s.mkBvar(0)),
        s.mkBvar(1));
    var result = s.substLooseBvars(e2, 0, &.{subs});    
    // Expect: fun a:A => fun b:B => g (h #2 #3) #2
    // std.debug.print("subs loosebvar range = {d}\n", .{em.getLooseBvarRange(subs)});
    // std.debug.print("e loosebvar range = {d}\n", .{em.getLooseBvarRange(e)});
    // std.debug.print("Result loosebvar range = {d}\n", .{em.getLooseBvarRange(result)});
    try std.testing.expect(em.getLooseBvarRange(result) == 2);
    try std.testing.expect(result.isLambda());
    result = em.getLambda(result).body;
    try std.testing.expect(result.isLambda());
    result = em.getLambda(result).body;
    try std.testing.expect(result.isApp());
    const app_g = em.getApp(result);
    try std.testing.expect(app_g.arg.isBvar());
    // std.debug.print("Result g_arg bvar id = {d}\n", .{app_g.arg.bvarId()});
    try std.testing.expect(app_g.arg.bvarId() == 2);
    const app_g_fun = em.getApp(app_g.fun);
    const app_h = em.getApp(app_g_fun.arg);
    try std.testing.expect(app_h.arg.bvarId() == 3);
    const app_h_fun = em.getApp(app_h.fun);
    try std.testing.expect(app_h_fun.arg.bvarId() == 2);
}

test "TypeChecker.whnf_core" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const s = ctx.gs;
    const em = ctx.em;

    const tc: *TypeChecker = .create(ctx.allocator, em, s, ctx.env);
    defer tc.destroy();

    const nf = 0;
    const X = s.mkFreeConst(1);
    const x0 = s.mkFreeConst(2);
    const x1 = s.mkFreeConst(3);
    // app ( app (fun x:X => fun y: => app #0 #1) x0) x1 = app x1 x0 
    const e = s.mkApp(s.mkApp(
                s.mkLambda(nf, X, s.mkLambda(nf, X, 
                s.mkApp (s.mkBvar(0), s.mkBvar(1)))),
            x0), x1);

    const res = tc.whnfCore(e);
    try std.testing.expect(res.isApp());
    try std.testing.expect(em.getApp(res).fun == x1);
    try std.testing.expect(em.getApp(res).arg == x0);

    // app (fun x:X => #0) #0 = #0
    try std.testing.expect(tc.whnfCore(s.mkApp(s.mkLambda(nf, X, s.mkBvar(0)), s.mkBvar(0))).bvarId() == 0);

    // app (fun x:X => #1) #2 = #0
    try std.testing.expect(tc.whnfCore(s.mkApp(s.mkLambda(nf, X, s.mkBvar(1)), s.mkBvar(2))).bvarId() == 0);

    // app (fun x:X => )
}

test "TypeChecker.unfoldDefinition" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const s = ctx.gs;
    const lm = ctx.lm;
    const em = ctx.em;
    const env = ctx.env;

    const cnFalse = 1;
    const Prop = s.mkSort(lm.mkZero());
    env.addAxiom(cnFalse, &.{}, Prop);
    const False = s.mkConst(cnFalse, &.{});
    try std.testing.expect(!env.find(cnFalse).?.hasValue()); // constant has no value field

    const cnNot = 2;
    const nA = 3;
    const Not_val = s.mkLambda(nA, Prop, s.mkForallE(0, s.mkBvar(0), False));
    env.addUnchecked(cnNot, &.{}, 
        s.mkForallE(0, Prop, Prop), 
        Not_val);
    const Not = s.mkConst(cnNot, &.{});

    const cnTrue = 4;
    const True_val = s.mkApp(Not, False);
    env.addUnchecked(cnTrue, &.{}, Prop, True_val);
    const True = s.mkConst(cnTrue, &.{});

    const True_info = env.find(cnTrue) orelse return error.TestUnexpectedResult;
    try std.testing.expect(True_info.hasValue());
    try std.testing.expect(True_info.getValue() == True_val);

    const tc: *TypeChecker = .create(ctx.allocator, em, s, env);
    defer tc.destroy();
    
    try std.testing.expect(tc.unfoldConst(False) == null);
    try std.testing.expect(tc.unfoldConst(True) == True_val);
    try std.testing.expect(tc.unfoldHeadConst(True_val) == s.mkApp(Not_val, False));

    const True_whnf = s.mkForallE(0, False, False);
    try std.testing.expect(tc.whnf(True) == True_whnf);

    // True: Prop
    const True_type = try tc.inferType(True, false);
    try std.testing.expect(True_type == Prop);

    // Prop: Sort 1
    const Prop_type = try tc.inferType(Prop, false);
    const Type = s.mkSort(lm.mkOne());
    try std.testing.expect(Prop_type == Type);

    // const cnIdProp: Name = 5;
    const IdProp = s.mkLambda(nA, Prop, s.mkBvar(0));
    const IdProp_type = try tc.inferType(IdProp, false);
    // fun A:Prop => A: Prop => Prop
    try std.testing.expect(IdProp_type == s.mkPi(nA, Prop, Prop));

    const nX: Name = 6;
    const na: Name = 7;
    // Id1 = fun X:Type => fun a:X => a
    // Id1 Prop: Pi a:Prop => Prop
    const Id1 = s.mkLambda(nX, Type, s.mkLambda(na, s.mkBvar(0), s.mkBvar(0)));
    const Id1_type = try tc.inferType(Id1, false);
    const cnId1: Name = 8;
    env.addUnchecked(cnId1, &.{}, Id1_type, Id1);
    const Id1_const = s.mkConst(cnId1, &.{});
    const Id1_Prop = s.mkApp(Id1_const, Prop);
    const Id1_Prop_type = try tc.inferType(Id1_Prop, false);
    try std.testing.expect(Id1_Prop_type.isPi());
    try std.testing.expect(em.getPi(Id1_Prop_type).binderType == Prop);
    try std.testing.expect(em.getPi(Id1_Prop_type).body == Prop);
}
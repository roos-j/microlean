const std = @import("std");
const oom = @import("common.zig").oom;
const Buffer = @import("common.zig").Buffer;
const Expr = @import("expr.zig").Expr;
const ExprManager = @import("expr.zig").ExprManager;
const ExprStore = @import("expr.zig").ExprStore;
const LevelManager = @import("level.zig").LevelManager;

pub const TypeChecker = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,
    em: *ExprManager,
    lm: *LevelManager,
    es: *ExprStore,
    whnf_cache: [2]std.hash_map.AutoHashMap(Expr, Expr),
    bvar_ctx: Buffer(Expr) = undefined, // bound variable local context

    // temporary buffers
    get_args_buf: Buffer(Expr) = undefined,

    pub fn create(allocator: std.mem.Allocator, em: *ExprManager, es: *ExprStore) *Self {
        const self = allocator.create(Self) catch oom();
        self.* = .{ .arena = .init(allocator),
            .em = em, .lm = em.lm, .whnf_cache = undefined,
            .es = es };
        self.whnf_cache = .{ .init(self.arena.allocator()), .init(self.arena.allocator()) };

        self.bvar_ctx = .init(self.arena.allocator());
        self.get_args_buf = .init(self.arena.allocator());
        return self;
    }

    pub fn destroy(self: *Self) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }

    /// Return weak head normal form, 'core' variant - here only beta reduction.
    /// This is a purely syntactic operation, no type checking.
    pub fn whnf_core(self: *Self, e: Expr) Expr {
        if (!e.isApp()) return e;
        if (self.whnf_cache[0].get(e)) |whnf_e| return whnf_e;

        const em = self.em;
        const es = self.es;
        var whnf_e: Expr = undefined;

        self.get_args_buf.clear();
        var f = em.getAppArgsRev(e, &self.get_args_buf);
        if (f.isLambda()) { // Beta reduction
            var n_lambdas: u32 = 1; // Count nested lambdas
            const n_apps = self.get_args_buf.len();
            var body = em.getLambda(f).body;
            while (body.isLambda() and n_lambdas < n_apps) {
                n_lambdas += 1;
                body = em.getLambda(body).body;
            }
            std.debug.assert(n_lambdas <= n_apps);
            // E.g. app( app( app (app (fun a => fun b => body[#0,#1]) arg0) arg1) arg2) arg3
            // Then args_buf = [arg3, arg2, arg1, arg0]
            // Should become: app (app body[arg1,arg0] arg2) arg3
            const cutoff_idx = n_apps - n_lambdas;
            const subst_args = self.get_args_buf.items()[cutoff_idx..];
            const body_subst = es.substLooseBvars(body, 0, subst_args);
            // Recover the unconsumed app's
            const remaining_args = self.get_args_buf.items()[0..cutoff_idx];
            whnf_e = es.mkAppArgsRev(body_subst, remaining_args);
            // Head could be a reducible app again, so recurse
            whnf_e = self.whnf_core(whnf_e);
        } else { // Cannot beta reduce, so nothing to do
            whnf_e = e;
        }

        self.whnf_cache[0].put(e, whnf_e) catch oom();
        return whnf_e;
    }

};
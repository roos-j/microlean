const std = @import("std");
const oom = @import("common.zig").oom;
const Buffer = @import("common.zig").Buffer;
const Expr = @import("expr.zig").Expr;
const ExprManager = @import("expr.zig").ExprManager;
const ExprStore = @import("expr.zig").ExprStore;
const LevelManager = @import("level.zig").LevelManager;
const Environment = @import("environment.zig").Environment;
const ConstantInfo = @import("environment.zig").ConstantInfo;

const KernelError = error{
    IllegalLooseBvars
};

pub const TypeChecker = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,
    em: *ExprManager,
    lm: *LevelManager,
    es: *ExprStore,
    env: *Environment,
    whnf_cache: [2]std.hash_map.AutoHashMap(Expr, Expr), // 0 is for core, 1 for full
    bvar_ctx: Buffer(Expr) = undefined, // bound variable local context

    // temporary buffers
    get_args_buf: Buffer(Expr) = undefined,

    pub fn create(allocator: std.mem.Allocator, em: *ExprManager, es: *ExprStore, env: *Environment) *Self {
        const self = allocator.create(Self) catch oom();
        self.* = .{ .arena = .init(allocator),
            .em = em, .lm = em.lm, .whnf_cache = undefined,
            .es = es, .env = env };
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
    pub fn whnfCore(self: *Self, e: Expr) Expr {
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
            whnf_e = self.whnfCore(whnf_e);
        } else { // Cannot beta reduce, so nothing to do
            whnf_e = e;
        }

        self.whnf_cache[0].put(e, whnf_e) catch oom();
        return whnf_e;
    }

    /// Try to find a const by looking up its definition in the environment.
    /// Will only return it if it has a value and if level parameter arity matches given const.
    pub fn findConstantInfo(self: *Self, e: Expr) ?ConstantInfo {
        std.debug.assert(e.isConst());
        const info: ConstantInfo = undefined;
        if (e.isFreeConst()) {
            if (self.env.find(e.constName())) |inf| { info = inf; }
            else { return null; }
            if (info.hasValue()) 
                return info;
        } else {
            if (self.env.find(self.em.getConstName(e))) |inf| { info = inf; } 
            else { return null; }
            if (!info.hasValue) return null;
            if (self.em.getNumLevelParams(e) == info.getNumLevelParams()) 
                return info;
        }
        return null;
    }

    /// Unfold a given constant: look it up in environment and then instantiate levels if applicable.
    pub fn unfoldConst(self: *Self, e: Expr) ?Expr {
        std.debug.assert(e.isConst());
        if (self.findConstantInfo(e)) |info| {
            std.debug.assert(info.hasValue());
            std.debug.assert(info.getNumLevelParams() == self.em.getNumLevelParams(e));
            if (!e.hasLevelParam()) {
                return info.getValue();
            } else {
                return self.es.substLevelParams(info.getValue(), 
                    info.getLevelParams(), self.em.getLevelParams(e));
            }
        }
        return null;
    }

    /// Unfold const at head of expression, i.e. if expression is a `const`,
    /// or if it is a chain of `app`.
    pub fn unfoldHeadConst(self: *Self, e: Expr) ?Expr {
        switch (e.kind()) {
            .cnst => return self.unfoldConst(e),
            .app => {
                const f = self.em.getAppsFun(e);
                if (self.unfoldConst(f)) |fval| {
                    self.get_args_buf.clear();
                    _ = self.em.getAppArgsRev(e);
                    return self.es.mkAppArgsRev(fval, self.get_args_buf.items());
                } else { return null; }
            },
            else => return null
        }
    }

};
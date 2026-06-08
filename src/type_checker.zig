const std = @import("std");
const oom = @import("common.zig").oom;
const log = @import("common.zig").log;
const Buffer = @import("common.zig").Buffer;
const Expr = @import("expr.zig").Expr;
const ExprManager = @import("expr.zig").ExprManager;
const ExprStore = @import("expr.zig").ExprStore;
const LevelManager = @import("level.zig").LevelManager;
const Environment = @import("environment.zig").Environment;
const ConstantInfo = @import("environment.zig").ConstantInfo;

pub const KernelError = error{
    IllegalLooseBvars, 
    UnknownConstant,
    ConstantAlreadyDeclared,
    DeclTypeMismatch, // Declared type does not match inferred type
    ExpectedSort, // Expr was expected to be a `sort`
    ExpectedPi, // Expr was expected to be a function type
    AppTypeMismatch, // App argument type does not match expected type
    Timeout // Deterministic timeout
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
        var info: ConstantInfo = undefined;
        if (e.isFreeConst()) {
            if (self.env.find(e.constName())) |inf| { info = inf; }
            else { return null; }
            if (info.hasValue()) 
                return info;
        } else {
            if (self.env.find(self.em.getConstName(e))) |inf| { info = inf; } 
            else { return null; }
            if (!info.hasValue()) return null;
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
                    _ = self.em.getAppArgsRev(e, &self.get_args_buf);
                    return self.es.mkAppArgsRev(fval, self.get_args_buf.items());
                } else { return null; }
            },
            else => return null
        }
    }

    /// Return weak head normal form.
    /// For the current language subset this means: recursively apply beta and delta reduction to head.
    pub fn whnf(self: *Self, e: Expr) Expr {
        switch (e.kind()) {
            .bvar, .forallE, .sort => return e,
            .lambda, .app, .cnst => {}
        }

        if (self.whnf_cache[1].get(e)) |whnf_e| {
            return whnf_e;
        }

        var whnf_e = e;
        while (true) {
            whnf_e = self.whnfCore(whnf_e);
            if (self.unfoldHeadConst(whnf_e)) |new_e| {
                whnf_e = new_e;
            } else {
                break;
            }
        }

        self.whnf_cache[1].put(e, whnf_e) catch oom();

        return whnf_e;
    }

    /// Infer type of an expression.
    /// If check is `true` then the output is guaranteed to be a well-formed
    /// type `t` satisfying `e: t`; otherwise only the checks required
    /// to build the inferred type are performed.
    pub fn inferType(self: *Self, e: Expr, check: bool) KernelError!Expr {
        if (self.bvar_ctx.len() < self.em.getLooseBvarRange(e)) {
            return KernelError.IllegalLooseBvars;
        }

        // ToDo: caching. Currently, could only cache when there is no bvar context
        // Either include bvar ctx in cache or use fvars like in Lean kernel
        
        return switch (e.kind()) {
            .bvar => self.inferBvar(e),
            .sort => self.inferSort(e),
            .cnst => self.inferConst(e),
            .app => self.inferApp(e, check),
            .lambda => self.inferLambda(e, check),
            .forallE => self.inferPi(e, check)
        };
    }

    /// Check that an expression is well-formed and has a well-formed type.
    /// Return type or throw error.
    pub fn checkType(self: *Self, e: Expr) KernelError!Expr {
        return try self.inferType(e, true);
    }

    /// Fetch type of bvar from local context.
    /// Note: In the actual Lean kernel this is instead
    /// implemented by adding fvar declarations into the local context
    /// when exploring the body of a binder, so that there are never loose bvars in inferType.
    pub fn inferBvar(self: *Self, e: Expr) Expr {
        std.debug.assert(e.isBvar());
        std.debug.assert(e.bvarId() < self.bvar_ctx.len());
        const idx = e.bvarId();
        const bvar_type = self.bvar_ctx.get(self.bvar_ctx.len() - 1 - idx);
        // adjust bvars in the type for nesting depth
        return self.es.liftLooseBvars(bvar_type, 0, idx+1);      
    }

    /// Type of `sort u` is `sort (u+1)`
    pub fn inferSort(self: *Self, e: Expr) Expr {
        std.debug.assert(e.isSort());
        if (e.hasLevelParam()) @panic("not yet implemented");
        return self.es.mkSort(self.lm.mkSucc(e.level()));
    }

    /// Look up type of `const` in environment. We assume the environment is trusted / type-checked.
    pub fn inferConst(self: *Self, e: Expr) KernelError!Expr {
        std.debug.assert(e.isConst());
        if (e.hasLevelParam()) @panic("not yet implemented");
        if (self.env.find(e.constName())) |info| {
            return info.getType();
        } else {
            return KernelError.UnknownConstant;
        }
    }

    pub fn inferApp(self: *Self, e: Expr, check: bool) KernelError!Expr {
        std.debug.assert(e.isApp());
        //if (check) @panic("not yet implemented");
        // TODO: treat chain of apps at once
        const app = self.em.getApp(e);
        var fun_type = try self.inferType(app.fun, check);
        fun_type = try self.ensurePi(fun_type);
        const pi = self.em.getPi(fun_type);
        if (check) {
            // Check that type of argument matches prescribed binder type
            const arg_type = try self.inferType(app.arg, check);
            if (!(try self.isDefEq(pi.binderType, arg_type))) {
                return KernelError.AppTypeMismatch;
            }
        }
        return self.es.substLooseBvars(pi.body, 0, &.{app.arg});
    }

    pub fn inferLambda(self: *Self, e: Expr, check: bool) KernelError!Expr {
        std.debug.assert(e.isLambda());
        // TODO: treat chain of lambdas 
        const lam = self.em.getLambda(e);
        // fun a:A => e should have type pi a:A => inferType(e)
        if (check) {
            const binderType_type = try self.inferType(lam.binderType, check);
            _ = try self.ensureSort(binderType_type);
        }
        self.bvar_ctx.append(lam.binderType); // register bvar in local ctx
        defer _ = self.bvar_ctx.pop();
        const body_type = try self.inferType(lam.body, check);
        return self.es.mkPi(lam.binderName, lam.binderType, body_type);
    }

    pub fn inferPi(self: *Self, e: Expr, check: bool) KernelError!Expr {
        std.debug.assert(e.isPi());
        // TODO: treat chain of lambdas
        const pi = self.em.getPi(e);
        // If e is pi a:A => body, and A: sort u and body: sort v,
        // then should e: Sort (imax(u, v))
        var sort_arg_type = try self.inferType(pi.binderType, check);
        sort_arg_type = try self.ensureSort(sort_arg_type);
        self.bvar_ctx.append(pi.binderType); // register bvar in local ctx
        defer _ = self.bvar_ctx.pop();
        var body_type = try self.inferType(pi.body, check);
        body_type = try self.ensureSort(body_type);
        return self.es.mkSort(self.lm.mkIMax(sort_arg_type.level(), body_type.level()));
    }

    /// Ensures that `e` is a dependent function type,
    /// possibly after passing to whnf. Return a pi or throw an error.
    pub fn ensurePi(self: *Self, e: Expr) KernelError!Expr {
        if (e.isPi()) return e;
        const whnf_e = self.whnf(e);
        if (whnf_e.isPi()) { return whnf_e; }
        else { return KernelError.ExpectedPi; }
    }

    /// Ensures that `e` is a sort,
    /// possibly after passing to whnf. Return a sort or throw an error.
    pub fn ensureSort(self: *Self, e: Expr) KernelError!Expr {
        if (e.isSort()) return e;
        const whnf_e = self.whnf(e);
        if (whnf_e.isSort()) { return whnf_e; }
        else { return KernelError.ExpectedSort; }
    }

    /// Attempt to prove that two given expressions are definitionally equal.
    /// We assume that the expressions are type-checked already.
    /// Return true on success. 
    pub fn isDefEq(self: *Self, e1: Expr, e2: Expr) KernelError!bool {
        if (e1.equal(e2)) return true;
        
        var e1_n = self.whnf(e1);
        var e2_n = self.whnf(e2);
        if (e1_n.equal(e2_n)) return true;

        // If the expressions are proofs of the same proposition, they are defeq.
        if (try self.isDefEqProofs(e1_n, e2_n)) return true;

        // at this point different expr kinds mean that they are not equal
        if (e1_n.kind() != e2_n.kind()) return false;
        switch (e1_n.kind()) {
            .bvar => {
                std.debug.assert(e1_n.bvarId() != e2_n.bvarId());
                return false;
            },
            .sort => {
                std.debug.assert(e1_n.level() != e2_n.level());   
                return self.isDefEqSort(e1_n, e2_n);
            },
            .cnst => return self.isDefEqConst(e1_n, e2_n),
            .app => return try self.isDefEqApp(e1_n, e2_n),
            .lambda => return try self.isDefEqLambda(e1_n, e2_n),
            .forallE => return try self.isDefEqPi(e1_n, e2_n)
        }

    }

    /// Proof irrelevance: Two expr's with propositional types
    /// are defeq if their types are defeq (i.e. they are proofs of defeq propositions).
    fn isDefEqProofs(self: *Self, e1: Expr, e2: Expr) KernelError!bool {
        const e1_type = try self.inferType(e1, false);
        if (!(try self.isProposition(e1_type))) {
            return false;
        }
        const e2_type = try self.inferType(e2, false);
        // Don't need to check that e2 is a Prop type, because isDefEq does that already
        // if (!(try self.isProposition(e2_type))) {
        //     return false;
        // }
        return try self.isDefEq(e1_type, e2_type);
    }

    /// Determines whether an expr has type `Prop`, i.e. is a proposition.
    /// Assumes `e` is type-correct.
    pub fn isProposition(self: *Self, e: Expr) KernelError!bool {
        const e_type_n = self.whnf(try self.inferType(e, false));
        return e_type_n.equal(self.es.mkProp());
    }

    /// Determines whether an expr has a propositional type, i.e. is a proof.
    /// Assumes `e` is type-correct.
    pub fn isProof(self: *Self, e: Expr) KernelError!bool {
        const e_type = try self.inferType(e, false);
        return try self.isProposition(e_type);
    }

    /// Two sort's are defeq if we can show that their levels are equal.
    fn isDefEqSort(self: *Self, e1: Expr, e2: Expr) bool {
        std.debug.assert(e1.isSort() and e2.isSort());
        return self.lm.equal(e1.level(), e2.level());
    }

    /// Two const's are defeq if their names are the same and their levels 
    /// can be shown to be equal.
    fn isDefEqConst(self: *Self, e1: Expr, e2: Expr) bool {
        std.debug.assert(e1.isConst() and e2.isConst());
        const c1 = self.em.getConst(e1);
        const c2 = self.em.getConst(e2);
        if (c1.constName != c2.constName) return false;
        if (c1.levels.len != c2.levels.len) return false;
        for (c1.levels, 0..) |lvl1, i| {
            const lvl2 = c2.levels[i];
            if (!self.lm.equal(lvl1, lvl2)) return false;
        }
        return true;
    }

    /// Two lambda's are defeq if both binderType and body are defeq.
    fn isDefEqLambda(self: *Self, e1: Expr, e2: Expr) KernelError!bool {
        std.debug.assert(e1.isLambda() and e2.isLambda());
        const lam1 = self.em.getLambda(e1);
        const lam2 = self.em.getLambda(e2);
        return try self.isDefEq(lam1.binderType, lam2.binderType) and
            try self.isDefEq(lam1.body, lam2.body);
    }

    /// Two pi's are defeq if both binderType and body are defeq.
    fn isDefEqPi(self: *Self, e1: Expr, e2: Expr) KernelError!bool {
        std.debug.assert(e1.isPi() and e2.isPi());
        const pi1 = self.em.getPi(e1);
        const pi2 = self.em.getPi(e2);
        return try self.isDefEq(pi1.binderType, pi2.binderType) and
            try self.isDefEq(pi1.body, pi2.body);
    }

    /// Two app's are defeq if both function and argument are defeq.
    fn isDefEqApp(self: *Self, e1: Expr, e2: Expr) KernelError!bool {
        std.debug.assert(e1.isApp() and e2.isApp());
        const app1 = self.em.getApp(e1);
        const app2 = self.em.getApp(e2);
        return try self.isDefEq(app1.fun, app2.fun) and
            try self.isDefEq(app1.arg, app2.arg);
    }
    
};
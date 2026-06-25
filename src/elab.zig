const std = @import("std");
const oom = @import("common.zig").oom;
const Buffer = @import("common.zig").Buffer;
const Pair = @import("common.zig").Pair;
const Name = @import("common.zig").Name;

const Parser = @import("parser.zig").Parser;
const ParserError = @import("parser.zig").ParserError;
const Term = @import("parser.zig").Term;
const TermNode = @import("parser.zig").TermNode;
const TermBinder = @import("parser.zig").TermBinder;

const Expr = @import("expr.zig").Expr;
const ExprManager = @import("expr.zig").ExprManager;
const ExprStore = @import("expr.zig").ExprStore;

const Environment = @import("environment.zig").Environment;

/// Elaborate `Term` into `Expr`.
/// 
/// Recursively visit the term:
/// 
/// ident -> becomes bvar (local ctx, preferred) or const (env lookup)
/// app -> straightforward recursion
/// lambda, pi -> push binder, recurse, pop binder
/// sort -> just copy level for now
pub const Elab = struct {
    const Self = @This();

    // allocator: std.mem.Allocator,
    p: *const Parser,
    // em: *const ExprManager,
    es: *ExprStore,
    env: *const Environment,

    local_ctx: Buffer(Name), // Stack of currently open bvars. A given identifier can appear multiple times
    
    pub fn init(allocator: std.mem.Allocator, parser: *const Parser, es: *ExprStore, env: *const Environment) Self {
        return .{ .p = parser, .es = es, .env = env,
                .local_ctx = .init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.local_ctx.deinit();
    }

    /// Elaborate a given term. No type checking.
    pub fn elabTerm(self: *Self, t: Term) ParserError!Expr {
        return try self.elabTermCore(t);
    }

    /// Push a bound variable to local context.
    fn pushBvar(self: *Self, n: Name) void {
        self.local_ctx.append(n);
    }

    /// Remove last bvar from local context.
    fn popBvar(self: *Self) void {
        _ = self.local_ctx.pop();
    }

    /// Resolve identifier to bvar as an `Expr` if it is found in local context,
    /// otherwise return `null`. Note that an identifier may appear multiple times
    /// in the local context. In that case, the most recent occurrence is returned.
    fn resolveBvar(self: *Self, n: Name) ?Expr {
        for (0..self.local_ctx.len()) |i| {
            if (self.local_ctx.get(self.local_ctx.len()-i-1) == n) return self.es.mkBvar(@intCast(i));
        }
        return null;
    }

    /// Resolve identifier. First attempt to resolve it as a bound variable from local context.
    /// Then attempt to resolve it as a constant from the environment.
    /// Return `null` on failure.
    fn resolveIdent(self: *Self, n: Name) ?Expr {
        if (self.resolveBvar(n)) |e| return e;
        if (self.env.find(n)) |info| {
            // ToDo: Support level parameters. Here we should make fresh universe level mvars
            // and substitute them into type and body, then later fill them
            std.debug.assert(info.getNumLevelParams() == 0);
            // const levels = info.getLevelParams();
            const e = self.es.mkFreeConst(n);
            return e;
        } else {
            return null;
        }
    }

    /// Elaborate a binder term (lambda or pi).
    fn elabBinder(self: *Self, b: TermBinder) ParserError!Pair(Expr, Expr) {
        // ToDo: use type inference to elaborate type
        std.debug.assert(b.binderType != null);
        const binderType = try self.elabTermCore(b.binderType.?);
        // Push bound variable before elaborating body
        self.pushBvar(b.binderName);
        defer self.popBvar();
        const body = try self.elabTermCore(b.body);
        return .mk(binderType, body);
    }

    fn elabTermCore(self: *Self, t: Term) ParserError!Expr {
        const node = self.p.getNode(t);
        switch (t.kind) {
            .ident => {
                if (self.resolveIdent(node.content.ident)) |e| return e
                else return self.p.unknownIdentifier(t);
            },
            .app => {
                const fun = try self.elabTermCore(node.content.app.fun);
                const arg = try self.elabTermCore(node.content.app.arg);
                return self.es.mkApp(fun, arg);
            },
            .lambda => {
                const lambda = node.content.lambda;
                const res = try self.elabBinder(lambda);
                return self.es.mkLambda(lambda.binderName, res.fst, res.snd);
            },
            .pi => {
                const pi = node.content.pi;
                const res = try self.elabBinder(pi);
                return self.es.mkPi(pi.binderName, res.fst, res.snd);
            },
            .sort => {
                // For now we just copy the level from the term.
                // Later separate term-level from expr-level
                const lvl = node.content.sort;
                return self.es.mkSort(lvl);
            }
        }
    }
};

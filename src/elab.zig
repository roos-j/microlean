const std = @import("std");
const oom = @import("common.zig").oom;
const Buffer = @import("common.zig").Buffer;
const Name = @import("common.zig").Name;

const Parser = @import("parser.zig").Parser;
const Term = @import("parser.zig").Term;
const TermNode = @import("parser.zig").TermNode;

const Expr = @import("expr.zig").Expr;
const ExprManager = @import("expr.zig").ExprManager;
const ExprStore = @import("expr.zig").ExprStore;

const Environment = @import("environment.zig").Environment;

const TypeChecker = @import("type_checker.zig").TypeChecker;

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
    arena: std.heap.ArenaAllocator,
    p: *const Parser,
    em: *const ExprManager,
    es: *ExprStore,
    env: *const Environment,

    local_ctx: std.AutoHashMap(Name, Expr),
    
    pub fn init(allocator: std.mem.Allocator, parser: *const Parser, em: *const ExprManager, es: *ExprStore, env: *const Environment) Self {
        const arena: std.heap.ArenaAllocator = .init(allocator);
        return .{ .arena = arena, .p = parser, .em = em, .es = es, .env = env,
                .local_ctx = .init(arena.allocator()) };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Elaborate a given term. No type checking.
    pub fn elabTerm(self: *Self, t: Term) Expr {
        return self.elabTerm(t);
    }

    fn elabTermCore(self: *Self, t: Term) Expr {
        const node = self.p.getNode(t);
        // switch (t.kind) {
        //     .ident => {

        //     }       
        // }
    }
};
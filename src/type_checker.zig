const std = @import("std");
const oom = @import("common.zig").oom;
const Expr = @import("expr.zig").Expr;
const ExprManager = @import("expr.zig").ExprManager;
const ExprStore = @import("expr.zig").ExprStore;
const LevelManager = @import("level.zig").LevelManager;

pub const TypeChecker = struct {

    
    arena: std.heap.ArenaAllocator,
    em: *ExprManager,
    lm: *LevelManager,
    whnf_cache: [2]std.hash_map.AutoHashMap(Expr, Expr),
    bvar_ctx: std.ArrayList(Expr) = .empty,

    pub fn create(allocator: std.mem.Allocator, em: *ExprManager) *TypeChecker {
        const self = allocator.create(TypeChecker) catch oom();
        self.* = .{ .arena = .init(allocator),
            .em = em, .lm = em.lm, .whnf_cache = undefined };
        self.whnf_cache = .{ .init(self.arena.allocator()), .init(self.arena.allocator()) };
        return self;
    }

    pub fn deinit(self: *TypeChecker) void {
        self.arena.deinit();
        self.deinit();
    }

    // pub fn infer_core(e: Expr, check: bool) Expr {
    //     return e;
    // }

};
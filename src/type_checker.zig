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

    /// Return weak head normal form, 'core' variant - here only beta reduction
    pub fn whnf_core(self: *Self, e: Expr) Expr {
        // const em = self.em;
        if (!e.isLambda()) return e;
        if (self.whnf_cache[0].get(e)) |whnf_e| return whnf_e;

        const whnf_e: Expr = undefined;
        self.get_args_buf.clear();
        //var f = em.getAppArgsRev(e, &self.get_args_buf);
        // if (f.isLambda()) { // Beta reduction
        //     // Todo
        // } else { // Cannot beta reduce, so nothing to do
        //     whnf_e = e;
        // }

        self.whnf_cache[0].put(e, whnf_e);
        return whnf_e;
    }

};
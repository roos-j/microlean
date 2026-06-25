const std = @import("std");
const Buffer = @import("src/common.zig").Buffer;
const Name = @import("src/common.zig").Name;
const LevelManager = @import("src/level.zig").LevelManager;
const Expr = @import("src/expr.zig").Expr;
const ExprManager = @import("src/expr.zig").ExprManager;
const ExprStore = @import("src/expr.zig").ExprStore;
const TypeChecker = @import("src/type_checker.zig").TypeChecker;
const Environment = @import("src/environment.zig").Environment;

pub const TestCtx = struct {
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
        const env = Environment.create(allocator, em);
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
const std = @import("std");
const oom = @import("common.zig").oom;
const Name = @import("common.zig").Name;
const Level = @import("level.zig").Level;
const LevelManager = @import("level.zig").LevelManager;

pub const Expr = u32;

pub const Idx = u32;

// A subset of Lean's Expr kinds, note `const` is a reserved keyword, so we use `cnst`
// Missing: fvar, mvar, letE, lit, mdata, proj
pub const ExprKind = enum { bvar, sort, cnst, app, lambda, forallE };

// Constant with universe levels
pub const ExprConst = struct {
    declName: Name,
    us: []const Level
};

// Function application
pub const ExprApp = struct {
    fun: Expr,
    arg: Expr
};

// We only include this as a placeholder for now, we only support default
// Missing: implicit, strictImplicit, instImplicit, rec
pub const BinderInfo = enum { default };

// Lambda expression
pub const ExprLambda = struct {
    binderName: Name,
    binderType: Expr,
    body: Expr,
    binderInfo: BinderInfo = .default
};

// Dependent function type
pub const ExprForallE = struct {
    binderName: Name,
    binderType: Expr,
    body: Expr,
    binderInfo: BinderInfo = .default
};

pub const ExprContent = union(ExprKind) {
    bvar: Idx,
    sort: Level,
    cnst: ExprConst,
    app: ExprApp,
    lambda: ExprLambda,
    forallE: ExprForallE,

    pub inline fn kind(self: ExprContent) ExprKind {
        return std.meta.activeTag(self);
    }

    pub fn hash(self: ExprContent) u64 {
        var h = std.hash.Wyhash.init(0);
        std.hash.autoHash(&h, self.kind());
        switch (self) {
            .cnst => |c| {
                std.hash.autoHash(&h, c.declName);
                for (c.us) |u| {
                    std.hash.autoHash(&h, u);
                }
            },
            .bvar, .sort => |a| { std.hash.autoHash(&h, a); },
            .app => |a| { std.hash.autoHash(&h, a); },
            .lambda => |a| { std.hash.autoHash(&h, a); },
            .forallE => |a| { std.hash.autoHash(&h, a); }
        }
        return h.final();
    }

    pub fn hash32(self: ExprContent) u32 {
        return @truncate(self.hash());
    }
};

// Computed Expr meta data
// same 64bit layout as in Lean 4 kernel
pub const ExprData = packed struct {
    hash: u32, // Lower 32bit of hash
    approx_depth: u8,
    _reserved: u3 = 0,
    has_level_param: bool,
    loose_bvar_range: u20, // max. de Brujin index + 1

    inline fn checkBvarRange(range: u32) void {
        if (range > std.math.maxInt(u20)) @panic("too many bound variables");
    }

    fn mkBvar(content: ExprContent) ExprData {
        const range = content.bvar + 1;
        checkBvarRange(range);
        return .{ .hash = undefined,
            .approx_depth = 0,
            .has_level_param = false,
            .loose_bvar_range = @intCast(range) };
    }

    fn mkSort(content: ExprContent, lm: *const LevelManager) ExprData {
        return .{ .hash = undefined,
            .approx_depth = 0,
            .has_level_param = lm.hasParam(content.sort),
            .loose_bvar_range = 0 };
    }

    fn mkConst(content: ExprContent, lm: *const LevelManager) ExprData {
        var has_param = false;
        for (content.cnst.us) |u| {
            if (lm.hasParam(u)) {
                has_param = true;
                break;
            }
        }
        return .{ .hash = undefined,
            .approx_depth = 0,
            .has_level_param = has_param,
            .loose_bvar_range = 0 };
    }

    inline fn incDepth(d: u8) u8 {
        if (d == 255) return 255;
        return d+1;
    }

    fn mkApp(content: ExprContent, em: *const ExprManager) ExprData {
        const depth = @max(incDepth(em.getApproxDepth(content.app.fun)),
            incDepth(em.getApproxDepth(content.app.arg)));
        const has_param = em.hasLevelParam(content.app.fun) or em.hasLevelParam(content.app.arg);
        const range = @max(em.getLooseBvarRange(content.app.fun), em.getLooseBvarRange(content.app.arg));
        return .{ .hash = undefined,
            .approx_depth = depth,
            .has_level_param = has_param,
            .loose_bvar_range = @intCast(range) };
    }

    // lambda or forallE
    fn mkBinder(binderType: Expr, body: Expr, em: *const ExprManager) ExprData {
        const depth = @max(incDepth(em.getApproxDepth(binderType)), incDepth(em.getApproxDepth(body)));
        const has_param = em.hasLevelParam(binderType) or em.hasLevelParam(body);
        const range = @max(em.getLooseBvarRange(binderType), em.getLooseBvarRange(body) -| 1);
        return .{ .hash = undefined,
            .approx_depth = depth,
            .has_level_param = has_param,
            .loose_bvar_range = @intCast(range) };
    }

    fn mkLambda(content: ExprContent, em: *const ExprManager) ExprData {
        return mkBinder(content.lambda.binderType, content.lambda.body, em);
    }

    fn mkForallE(content: ExprContent, em: *const ExprManager) ExprData {
        return mkBinder(content.forallE.binderType, content.forallE.body, em);
    }
};

pub const ExprNode = struct {
    content: ExprContent, // logical content
    data: ExprData, // computed meta data

    // Does not compute hash!
    pub fn init(content: ExprContent, em: *const ExprManager) ExprNode {
        const data: ExprData = switch (content) {
            .bvar => .mkBvar(content),
            .sort => .mkSort(content, em.lm),
            .cnst => .mkConst(content, em.lm),
            .app => .mkApp(content, em),
            .lambda => .mkLambda(content, em),
            .forallE => .mkForallE(content, em)
        };
        return .{ .content = content, .data = data };
    }
};

pub const ExprManager = struct {
    const Self = @This();

    const Context = struct {
        pub fn hash(_: Context, key: ExprContent) u64 {
            return key.hash();
        }

        pub fn eql(_: Context, a: ExprContent, b: ExprContent) bool {
            if (a.kind() != b.kind()) return false;
            return switch (a) {
                .cnst => |c| c.declName == b.cnst.declName 
                    and std.mem.eql(Level, c.us, b.cnst.us),
                else => std.meta.eql(a, b)
            };
        }
    };

    allocator: std.mem.Allocator,
    nodes: std.ArrayList(ExprNode) = .empty,
    hash_map: std.HashMap(ExprContent, Expr, Context, 80), // Todo: custom hash map for further optimization
    lm: *const LevelManager,

    pub fn init(allocator: std.mem.Allocator, lm: *const LevelManager) Self {
        const self: Self = .{ .allocator = allocator, .hash_map = .init(allocator), .lm = lm };
        return self;
    }

    pub fn cache(self: *Self, content: ExprContent) Expr {
        const result = self.hash_map.getOrPut(content) catch oom();
        if (result.found_existing) {
            return result.value_ptr.*;
        }
        const new_id: Expr = @intCast(self.nodes.items.len);
        result.value_ptr.* = new_id;
        var node: ExprNode = .init(content, self);
        node.data.hash = content.hash32(); // could avoid double hash call, but probably not important
        self.nodes.append(self.allocator, node) catch oom();
        return new_id;       
    }

    pub fn mkBvar(self: *Self, idx: Idx) Expr {
        return self.cache(.{ .bvar = idx });
    }

    pub fn mkSort(self: *Self, lvl: Level) Expr {
        return self.cache(.{ .sort = lvl });
    }

    pub fn mkConst(self: *Self, declName: Name, us: []const Level) Expr {
        return self.cache(.{ .cnst = .{.declName = declName, .us = us} });
    }

    pub fn mkApp(self: *Self, fun: Expr, arg: Expr) Expr {
        return self.cache(.{ .app = .{.fun = fun, .arg = arg} });
    }

    pub fn mkLambda(self: *Self, binderName: Name, binderType: Expr, body: Expr) Expr {
        return self.cache(.{ .lambda = .{ .binderName = binderName, .binderType = binderType, .body = body } });
    }

    pub fn mkForallE(self: *Self, binderName: Name, binderType: Expr, body: Expr) Expr {
        return self.cache(.{ .forallE = .{ .binderName = binderName, .binderType = binderType, .body = body } });
    }

    pub fn getNode(self: *const Self, e: Expr) ExprNode {
        return self.nodes.items[e];
    }

    pub fn getApproxDepth(self: *const Self, e: Expr) u8 {
        return self.getNode(e).data.approx_depth;
    }

    pub fn hasLevelParam(self: *const Self, e: Expr) bool {
        return self.getNode(e).data.has_level_param;
    }

    pub fn getLooseBvarRange(self: *const Self, e: Expr) u32 {
        return self.getNode(e).data.loose_bvar_range;
    }

    pub fn getHash32(self: *const Self, e: Expr) u32 {
        return self.getNode(e).data.hash;
    }

    pub fn getKind(self: *const Self, e: Expr) ExprKind {
        return self.getNode(e).content.kind();
    }
};
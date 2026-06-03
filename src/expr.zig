const std = @import("std");
const builtin = @import("builtin");
const oom = @import("common.zig").oom;
const Buffer = @import("common.zig").Buffer;
const Name = @import("common.zig").Name;
const Level = @import("level.zig").Level;
const LevelManager = @import("level.zig").LevelManager;

pub const ExprIdx = u32;
pub const ExprStoreId = u32;

pub const Expr = packed struct {
    idx: ExprIdx, // Index to an array
    storeId: ExprStoreId = 0 // Store id, typically points to an Array
};

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

// ToDo later: optimize size
// bvar, const can be immediate / encode in Expr handle
// Exploit different node sizes for different kinds
pub const ExprNode = struct {
    content: ExprContent, // logical content
    data: ExprData, // computed meta data

    // Does not compute hash
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

// One global ExprManager resolved all Expr handles
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
    globalStore: ExprStore,
    lm: *const LevelManager,
    stores: std.ArrayList(*ExprStore) = .empty, // ExprStoreId is an index into this store

    pub fn create(allocator: std.mem.Allocator, lm: *const LevelManager) *ExprManager {
        const self = allocator.create(ExprManager) catch oom();
        self.* = .{ .allocator = allocator, 
             .globalStore = undefined,
            .lm = lm };
        self.globalStore.init(self.allocator, self, 0);
        self.stores.append(self.allocator, &self.globalStore) catch oom();
        return self;
    }

    pub fn destroy(self: *Self) void {
        for (self.stores.items) |store| {
            store.deinit();
            if (store != &self.globalStore) self.allocator.destroy(store);
        }
        self.stores.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn getGlobalStore(self: *Self) *ExprStore {
        std.debug.assert(self.stores.items.len > 0);
        return &self.globalStore;
    }

    pub fn getStore(self: *Self, storeId: ExprStoreId) *ExprStore {
        std.debug.assert(storeId < self.stores.items.len);
        const store = self.stores.items[storeId];
        std.debug.assert(store.isOpen);
        return store;
    }

    /// Obtain a fresh ExprStore, creating a new one if necessary. Use this for temporary ExprStores
    pub fn createStore(self: *Self) *ExprStore {
        std.debug.assert(self.stores.items.len > 0); // Check if global store was initialized
        // Check if there is a previously closed store available
        var storeId: ?ExprStoreId = null;
        for (self.stores.items, 0..) |store, i| {
            if (!store.isOpen) { // Reopen this store
                storeId = store.storeId;
                std.debug.assert(storeId.? == i);
                store.isOpen = true;
                std.debug.assert(store.nodes.items.len == 0);
                std.debug.assert(store.hashMap.count() == 0);
                break;
            }
        }
        std.debug.assert(storeId orelse 1 > 0);
        if (storeId == null) {
            storeId = @intCast(self.stores.items.len);
            const new_store = self.allocator.create(ExprStore) catch oom();
            new_store.init(self.allocator, self, storeId.?);
            self.stores.append(self.allocator, new_store) catch oom();
        }
        return self.stores.items[storeId.?];
    }

    /// Close an ExprStore after use.
    /// Important: this will only clear all the data in the store and mark the empty store closed (available for future use).
    pub fn closeStore(self: *Self, storeId: ExprStoreId) void {
        std.debug.assert(storeId != 0); // Cannot close global store
        std.debug.assert(storeId < self.stores.items.len);
        const store = self.stores.items[storeId];
        std.debug.assert(store.isOpen);
        store.clear();
        store.isOpen = false;
    }

    pub fn getNode(self: *const Self, e: Expr) ExprNode {
        std.debug.assert(e.storeId < self.stores.items.len);
        return self.stores.items[e.storeId].getNode(e);
    }

    pub inline fn getApproxDepth(self: *const Self, e: Expr) u8 {
        return self.getNode(e).data.approx_depth;
    }

    pub inline fn hasLevelParam(self: *const Self, e: Expr) bool {
        return self.getNode(e).data.has_level_param;
    }

    pub inline fn getLooseBvarRange(self: *const Self, e: Expr) u32 {
        return self.getNode(e).data.loose_bvar_range;
    }

    pub inline fn getHash32(self: *const Self, e: Expr) u32 {
        return self.getNode(e).data.hash;
    }

    pub inline fn kind(self: *const Self, e: Expr) ExprKind {
        return self.getNode(e).content.kind();
    }

    pub inline fn isBvar(self: *const Self, e: Expr) bool {
        return self.kind(e) == .bvar;
    }

    pub inline fn isSort(self: *const Self, e: Expr) bool {
        return self.kind(e) == .sort;
    }

    pub inline fn isConst(self: *const Self, e: Expr) bool {
        return self.kind(e) == .cnst;
    }

    pub inline fn isApp(self: *const Self, e: Expr) bool {
        return self.kind(e) == .app;
    }

    pub inline fn isLambda(self: *const Self, e: Expr) bool {
        return self.kind(e) == .lambda;
    }

    pub inline fn isPi(self: *const Self, e: Expr) bool {
        return self.kind(e) == .forallE;
    }

    pub inline fn isAtomic(self: *const Self, e: Expr) bool {
        return switch (self.kind(e)) {
            .bvar, .sort, .cnst => true,
            else => false
        };
    }

    pub inline fn getApp(self: *const Self, e: Expr) ExprApp {
        return self.getNode(e).content.app;
    }

    /// Unwrap function applications, store arguments in reversed order and return head function
    pub fn getAppArgsRev(self: *const Self, e: Expr, args: *Buffer(Expr)) Expr {
        var curr = e;
        while (self.isApp(curr)) {
            args.append(self.getApp(curr).arg);
            curr = self.getApp(curr).fun;
        }
        return curr;
    }
};

// Later: special bvar and sort 'stores' which are not actually stores
pub const ExprStoreKind = enum { default };

// // Store handle for the stores array in the manager
// pub const ExprStoreHandle = union(ExprStoreKind) {
//     default: *ExprStore
// };

pub const ExprStore = struct {
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

    storeId: ExprStoreId,
    isOpen: bool = true, // Whether store is currently in active use
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(ExprNode) = .empty, 
    hashMap: std.HashMap(ExprContent, ExprIdx, Context, 80),
    lm: *const LevelManager,
    em: *const ExprManager,

    pub fn init(self: *Self, allocator: std.mem.Allocator, em: *const ExprManager, storeId: ExprStoreId) void {
        self.* = .{ .storeId = storeId, 
            .arena = .init(allocator), 
            .hashMap = undefined, 
            .lm = em.lm,
            .em = em };
        self.hashMap = .init(self.arena.allocator());
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    fn cache(self: *Self, content: ExprContent) Expr {
        if (comptime builtin.mode == .Debug) self.enforceNoCrossStoreReference(content);
        const result = self.hashMap.getOrPut(content) catch oom();
        if (result.found_existing) {
            return .{ .storeId = self.storeId, .idx = result.value_ptr.* };
        }
        const new_id: ExprIdx = @intCast(self.nodes.items.len);
        result.value_ptr.* = new_id;
        var node: ExprNode = .init(content, self.em);
        node.data.hash = content.hash32(); // could avoid double hash call, but probably not important
        self.nodes.append(self.arena.allocator(), node) catch oom();
        return .{ .storeId = self.storeId, .idx = new_id };       
    }

    /// An Expr cannot reference another store other than the global store.
    fn enforceNoCrossStoreReference(self: *const Self, content: ExprContent) void {
        switch (content) {
            .bvar, .sort, .cnst => return,
            .app => |app| {
                std.debug.assert(self.storeIdAllowed(app.fun));
                std.debug.assert(self.storeIdAllowed(app.arg));
            },
            .lambda => |b| {
                std.debug.assert(self.storeIdAllowed(b.binderType));
                std.debug.assert(self.storeIdAllowed(b.body));
            },
            .forallE => |b| {
                std.debug.assert(self.storeIdAllowed(b.binderType));
                std.debug.assert(self.storeIdAllowed(b.body));
            },
        }
    }

    fn storeIdAllowed(self: *const Self, e: Expr) bool {
        return e.storeId == 0 or self.storeId == e.storeId;
    }

    /// Clear all data in the store, but retaining memory capacity for efficiency
    pub fn clear(self: *Self) void {
        std.debug.assert(self.isOpen);
        _ = self.arena.reset(.retain_capacity);
        self.nodes = .empty;
        self.hashMap = .init(self.arena.allocator());
    }

    pub fn getNode(self: *const Self, e: Expr) ExprNode {
        std.debug.assert(e.storeId == self.storeId);
        std.debug.assert(self.isOpen);
        return self.nodes.items[e.idx];
    }

    pub fn mkBvar(self: *Self, idx: Idx) Expr {
        std.debug.assert(self.isOpen);
        return self.cache(.{ .bvar = idx });
    }

    pub fn mkSort(self: *Self, lvl: Level) Expr {
        std.debug.assert(self.isOpen);
        return self.cache(.{ .sort = lvl });
    }

    pub fn mkConst(self: *Self, declName: Name, us: []const Level) Expr {
        std.debug.assert(self.isOpen);
        // ToDo: This is potentially very inefficient for now, memcpy even happens before cache
        // Use a builder pattern or similar later
        const local_us = self.arena.allocator().dupe(Level, us) catch oom();
        return self.cache(.{ .cnst = .{.declName = declName, .us = local_us} });
    }

    pub fn mkApp(self: *Self, fun: Expr, arg: Expr) Expr {
        std.debug.assert(self.isOpen);
        return self.cache(.{ .app = .{.fun = fun, .arg = arg} });
    }

    pub fn mkLambda(self: *Self, binderName: Name, binderType: Expr, body: Expr) Expr {
        std.debug.assert(self.isOpen);
        return self.cache(.{ .lambda = .{ .binderName = binderName, .binderType = binderType, .body = body } });
    }

    pub fn mkForallE(self: *Self, binderName: Name, binderType: Expr, body: Expr) Expr {
      std.debug.assert(self.isOpen);
      return self.cache(.{ .forallE = .{ .binderName = binderName, .binderType = binderType, .body = body } });
    }
};
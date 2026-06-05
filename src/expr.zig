const std = @import("std");
const builtin = @import("builtin");
const oom = @import("common.zig").oom;
const Buffer = @import("common.zig").Buffer;
const Name = @import("common.zig").Name;
const Level = @import("level.zig").Level;
const LevelManager = @import("level.zig").LevelManager;

pub const ExprIdx = u32;
pub const ExprStoreId = u16;

pub const ExprImmData = packed union {
    idx: ExprIdx, // for non-immediates. Index to store's ExprNode array
    bvarId: Idx,
    lvl: Level,
    name: Name
};

pub const Expr = packed struct {
    data: ExprImmData, // 32 bit. Index to the store's ExprNode array
    
    _kind: ExprKind, // 4 bit
    _has_level_param: bool,
    _reserved: u11 = 0,

    _storeId: ExprStoreId = 0, // 16 bit, only used for non-immediates

    pub inline fn kind(e: Expr) ExprKind { return e._kind; }
    pub inline fn isBvar(e: Expr) bool { return e.kind() == .bvar; }
    pub inline fn isSort(e: Expr) bool { return e.kind() == .sort; }
    pub inline fn isConst(e: Expr) bool { return e.kind() == .cnst; }
    pub inline fn isApp(e: Expr) bool { return e.kind() == .app; }
    pub inline fn isLambda(e: Expr) bool { return e.kind() == .lambda; }
    pub inline fn isPi(e: Expr) bool { return e.kind() == .forallE; }

    pub inline fn hasLevelParam(e: Expr) bool { return e._has_level_param; }

    /// A free const is one without universe level parameters
    pub inline fn isFreeConst(e: Expr) bool { return e.isConst() and !e.hasLevelParam(); }

    /// Literal equality of expression -- for bvar, only idx counts; for sort only level
    /// For Const, names will be store-dependent, so we use exact equality
    pub inline fn equal(e1: Expr, e2: Expr) bool {
        if (e1 == e2) return true;
        if (e1.isBvar() and e2.isBvar()) {
            return e1.bvarId() == e2.bvarId();
        } else if (e1.isSort() and e2.isSort()) {
            return e1.level() == e2.level();
        } else {
            return false;
        }
    }

    /// Immediates are completely encoded in `Expr`, non-immediates have an associated `ExprNode` which is cached
    pub inline fn isImmediate(e: Expr) bool {
        return e.isBvar() or e.isSort() or e.isFreeConst();
    }

    pub inline fn isAtomic(e: Expr) bool {
        return switch (e.kind()) {
            .bvar, .sort, .cnst => true,
            else => false
        };
    }

    pub inline fn idx(e: Expr) ExprIdx {
        std.debug.assert(!e.isImmediate());
        return e.data.idx;
    }

    pub inline fn storeId(e: Expr) ExprStoreId {
        return e._storeId;
    }

    pub inline fn bvarId(e: Expr) Idx {
        std.debug.assert(e.isBvar());
        return e.data.bvarId;
    }

    pub inline fn level(e: Expr) Level {
        std.debug.assert(e.isSort());
        return e.data.lvl;
    }

    pub inline fn constName(e: Expr) Name {
        std.debug.assert(e.isFreeConst());
        return e.data.name;
    }

    pub inline fn getBvarRange(e: Expr) Idx {
        std.debug.assert(e.isImmediate());
        switch (e.kind()) {
            .bvar => return e.bvarId() + 1,
            .sort, .cnst => return 0,
            else => unreachable
        }
    }
};

pub const Idx = u32;

// A subset of Lean's Expr kinds, note `const` is a reserved keyword, so we use `cnst`
// Missing: fvar, mvar, letE, lit, mdata, proj
pub const ExprKind = enum(u4) { bvar, sort, cnst, app, lambda, forallE };

// Constant with universe levels
pub const ExprConst = struct {
    constName: Name,
    levels: []const Level
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

// ToDo: Make this more memory efficient; the different kinds have different sizes
pub const ExprContent = union(ExprKind) {
    bvar: Idx, // ToDo: now stored in Expr directly, but we still use the tag of this union
    sort: Level, // Same
    cnst: ExprConst,
    app: ExprApp,
    lambda: ExprLambda,
    forallE: ExprForallE,

    pub fn hash(self: ExprContent) u64 {
        var h = std.hash.Wyhash.init(0);
        std.hash.autoHash(&h, self.kind());
        switch (self) {
            .cnst => |c| {
                std.hash.autoHash(&h, c.constName);
                for (c.levels) |u| {
                    std.hash.autoHash(&h, u);
                }
            },
            .bvar, .sort => unreachable, //|a| { std.hash.autoHash(&h, a); },
            .app => |a| { std.hash.autoHash(&h, a); },
            .lambda => |a| { std.hash.autoHash(&h, a); },
            .forallE => |a| { std.hash.autoHash(&h, a); }
        }
        return h.final();
    }

    pub fn hash32(self: ExprContent) u32 {
        return @truncate(self.hash());
    }

    pub fn kind(content: ExprContent) ExprKind {
        return std.meta.activeTag(content);
    }
};

/// Computed Expr meta data
/// Todo: see if it makes sense to cache some info about nested app's (here or in Expr)
pub const ExprData = packed struct {
    // same 64bit layout as in Lean 4 kernel
    hash: u32, // Lower 32bit of hash
    approx_depth: u8,
    _reserved: u3 = 0, // unimplemented Lean 4 features
    has_level_param: bool, // Stored in `Expr` but still needed here for cached Expr's
    loose_bvar_range: u20, // max. de Brujin index + 1

    /// Check that bvar range doesn't exceed maximum
    inline fn checkBvarRange(range: u32) void {
        if (range > std.math.maxInt(u20)) @panic("too many bound variables");
    }

    // Obsolete now?
    fn mkBvar(content: ExprContent) ExprData {
        const range = content.bvar + 1;
        checkBvarRange(range);
        return .{ .hash = undefined,
            .approx_depth = 0,
            .has_level_param = false,
            .loose_bvar_range = @intCast(range) };
    }

    // Obsolete now?
    fn mkSort(content: ExprContent, lm: *const LevelManager) ExprData {
        return .{ .hash = undefined,
            .approx_depth = 0,
            .has_level_param = lm.hasParam(content.sort),
            .loose_bvar_range = 0 };
    }

    fn mkConst(content: ExprContent, lm: *const LevelManager) ExprData {
        var has_param = false;
        for (content.cnst.levels) |u| {
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
        const has_param = content.app.fun.hasLevelParam() or content.app.arg.hasLevelParam();
        const range = @max(em.getLooseBvarRange(content.app.fun), em.getLooseBvarRange(content.app.arg));
        return .{ .hash = undefined,
            .approx_depth = depth,
            .has_level_param = has_param,
            .loose_bvar_range = @intCast(range) };
    }

    // lambda or forallE
    fn mkBinder(binderType: Expr, body: Expr, em: *const ExprManager) ExprData {
        const depth = @max(incDepth(em.getApproxDepth(binderType)), incDepth(em.getApproxDepth(body)));
        const has_param = binderType.hasLevelParam() or body.hasLevelParam();
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

    // Does not compute hash
    pub fn init(content: ExprContent, em: *const ExprManager) ExprNode {
        const data: ExprData = switch (content) {
            .bvar => unreachable, //.mkBvar(content), // obsolete?
            .sort => unreachable, //.mkSort(content, em.lm), // obsolete?
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
                .cnst => |c| c.constName == b.cnst.constName 
                    and std.mem.eql(Level, c.levels, b.cnst.levels),
                else => std.meta.eql(a, b)
            };
        }
    };

    allocator: std.mem.Allocator,
    globalStore: ExprStore,
    lm: *LevelManager,
    stores: std.ArrayList(*ExprStore) = .empty, // ExprStoreId is an index into this store

    pub fn create(allocator: std.mem.Allocator, lm: *LevelManager) *ExprManager {
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
        if (self.stores.items.len >= std.math.maxInt(ExprStoreId)) {
            @panic("maximum number of stores can't be exceeded.");
        }
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
        std.debug.assert(!e.isImmediate());
        std.debug.assert(e.storeId() < self.stores.items.len);
        return self.stores.items[e.storeId()].getNode(e);
    }

    pub inline fn getApproxDepth(self: *const Self, e: Expr) u8 {
        if (e.isAtomic()) return 0;
        return self.getNode(e).data.approx_depth;
    }

    // pub inline fn hasLevelParam(self: *const Self, e: Expr) bool {
    //     return self.getNode(e).data.has_level_param;
    // }

    pub inline fn getLooseBvarRange(self: *const Self, e: Expr) u32 {
        if (e.isImmediate()) {
            return e.getBvarRange();
        } else {
            return self.getNode(e).data.loose_bvar_range;
        }
    }

    pub inline fn hasLooseBvars(self: *const Self, e: Expr) bool {
        return self.getLooseBvarRange(e) > 0;
    }

    pub inline fn getLevelParams(self: *const Self, e: Expr) []const Level {
        std.debug.assert(e.isConst() and e.hasLevelParam());
        return self.getNode(e).content.cnst.levels;
    }

    pub inline fn getNumLevelParams(self: *const Self, e: Expr) u32 {
        std.debug.assert(e.isConst());
        return if (e.hasLevelParam()) self.getNode(e).content.cnst.levels.len else 0;
    }

    pub inline fn getHash32(self: *const Self, e: Expr) u32 {
        std.debug.assert(!e.isImmediate()); // can still get a hash for imm, but shouldn't be needed
        return self.getNode(e).data.hash;
    }

    pub inline fn getConstName(self: *const Self, e: Expr) Name {
        std.debug.assert(e.isConst());
        if (e.isImmediate()) return e.constName();
        return self.getNode(e).content.cnst.constName;
    }

    pub inline fn getConst(self: *const Self, e: Expr) ExprConst {
        std.debug.assert(e.isConst());
        if (e.isImmediate()) return .{ .constName = e.constName(), .levels = &.{} };
        return self.getNode(e).content.cnst;
    }

    pub inline fn getLambda(self: *const Self, e: Expr) ExprLambda {
        std.debug.assert(e.isLambda());
        return self.getNode(e).content.lambda;
    }

    pub inline fn getPi(self: *const Self, e: Expr) ExprForallE {
        std.debug.assert(e.isPi());
        return self.getNode(e).content.forallE;
    }

    pub inline fn getApp(self: *const Self, e: Expr) ExprApp {
        std.debug.assert(e.isApp());
        return self.getNode(e).content.app;
    }

    /// If `e` is `app (app (app .. (app f arg0 ) arg1 ..`, return `f`.
    pub inline fn getAppsFun(self: *const Self, e: Expr) Expr {
        std.debug.assert(e.isApp());
        var e1 = e;
        while (e1.isApp()) {
            e1 = self.getApp().fun;
        }
        return e1;
    }

    /// Unwrap function applications, store arguments in reversed order and return head function
    /// E.g. `app (app (app f a0) a1) a2` will be stored as `[a2, a1, a0]`
    pub fn getAppArgsRev(self: *const Self, e: Expr, args: *Buffer(Expr)) Expr {
        var curr = e;
        while (curr.isApp()) {
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
                .cnst => |c| c.constName == b.cnst.constName 
                    and std.mem.eql(Level, c.levels, b.cnst.levels),
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
        const kind = content.kind();
        const result = self.hashMap.getOrPut(content) catch oom();
        if (result.found_existing) {
            const id: ExprIdx = result.value_ptr.*;
            const has_level_param = self.nodes.items[id].data.has_level_param;
            return .{ ._storeId = self.storeId, 
                 ._kind = kind,
                 ._has_level_param = has_level_param,    
                .data = .{ .idx = id } };
        }
        const new_id: ExprIdx = @intCast(self.nodes.items.len);
        result.value_ptr.* = new_id;
        var node: ExprNode = .init(content, self.em);
        node.data.hash = content.hash32(); // could avoid double hash call, but probably not important
        self.nodes.append(self.arena.allocator(), node) catch oom();
        return .{ ._kind = kind, ._storeId = self.storeId, 
            ._has_level_param = node.data.has_level_param,
            .data = .{ .idx = new_id } };       
    }

    /// An Expr cannot reference another store other than the current one or global store.
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
        return e.storeId() == 0 or self.storeId == e.storeId();
    }

    /// Clear all data in the store, but retaining memory capacity for efficiency
    pub fn clear(self: *Self) void {
        std.debug.assert(self.isOpen);
        _ = self.arena.reset(.retain_capacity);
        self.nodes = .empty;
        self.hashMap = .init(self.arena.allocator());
    }

    pub fn getNode(self: *const Self, e: Expr) ExprNode {
        std.debug.assert(!e.isImmediate());
        std.debug.assert(e.storeId() == self.storeId);
        std.debug.assert(self.isOpen);
        return self.nodes.items[e.idx()];
    }

    /// Make a bound variable.
    /// `bvar` is immediate and doesn't actually require the store, but we still keep track of storeId
    pub fn mkBvar(self: *Self, idx: Idx) Expr {
        std.debug.assert(self.isOpen);
        ExprData.checkBvarRange(idx);
        return .{ ._kind = .bvar, 
            ._has_level_param = false, 
            .data = .{.bvarId = idx},
            ._storeId = self.storeId };
        //return self.cache(.{ .bvar = idx });
    }

    pub fn mkSort(self: *Self, lvl: Level) Expr {
        std.debug.assert(self.isOpen);
        const has_param = self.lm.hasParam(lvl);
        return .{ ._kind = .sort, 
            ._has_level_param = has_param, 
            .data = .{.lvl = lvl}, 
            ._storeId = self.storeId };
        // return self.cache(.{ .sort = lvl });
    }

    /// Make a `const` without level parameters
    pub fn mkFreeConst(self: *Self, declName: Name) Expr {
        std.debug.assert(self.isOpen);
        return .{ ._kind = .cnst, 
            ._has_level_param = false, 
            .data = .{ .name = declName }, 
            ._storeId = self.storeId };
    }

    pub fn mkConst(self: *Self, declName: Name, us: []const Level) Expr {
        std.debug.assert(self.isOpen);
        if (us.len == 0) return self.mkFreeConst(declName);
        // ToDo: This is potentially very inefficient for now, memcpy even happens before cache
        // Use a builder pattern or similar later
        const local_us = self.arena.allocator().dupe(Level, us) catch oom();
        return self.cache(.{ .cnst = .{.constName = declName, .levels = local_us} });
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

    /// Make a function application with multiple arguments in forward order: (f args[0]) args[1] ..
    pub fn mkAppArgs(self: *Self, f: Expr, args: []const Expr) Expr {
        var e = f;
        for (args) |arg| {
            e = self.mkApp(e, arg);
        }
        return e;
    }

    /// Make a function application with multiple arguments in reverse order: (f args[n-1]) args[n-2] ..
    pub fn mkAppArgsRev(self: *Self, f: Expr, args: []const Expr) Expr {
        var e = f;
        const n = args.len;
        for (0..n) |i| {
            const revi = n - 1 - i;
            e = self.mkApp(e, args[revi]);
        }
        return e;
    }

    /// Recursively visit all subexpressions and apply `f` to them.
    /// If `f` provides an Expr, then replace the current subexpression. Substituted expressions are not traversed further.
    /// `f` takes the current subexpression and the number of binders it is contained in relative to the top level expression.
    /// Return the resulting full expression.
    pub fn replace(self: *Self, ctx: anytype, e: Expr, f: fn (anytype, Expr, u32) ?Expr) Expr {
        return self.replace_rec( ctx, e,f, 0);
    }

    // ToDo: make this go through a cache for fixed f. Key is (e,offset) and output is result
    fn replace_rec(self: *Self, ctx: anytype, e: Expr, f: fn (anytype, Expr, u32) ?Expr, offset: u32) Expr {
        const em = self.em;
        const subst = f(ctx, e, offset);
        if (subst) |new_e| {
            return new_e;
        }
        if (e.isAtomic()) return e;
        switch (em.getNode(e).content) {
            .bvar, .sort, .cnst => unreachable,
            .app => |app| {
                const newfun = self.replace_rec(ctx, app.fun, f, offset);
                const newarg = self.replace_rec(ctx, app.arg, f, offset);
                if (newfun == app.fun and newarg == app.arg) return e; // ToDo: do we need to use Expr.equal here?
                const new_e = self.mkApp(newfun, newarg);
                return new_e;
            },
            .lambda => |lam| {
                const newtype = self.replace_rec(ctx, lam.binderType, f, offset);
                const newbody = self.replace_rec(ctx, lam.body, f, offset + 1);
                if (newtype == lam.binderType and newbody == lam.body) return e;
                const new_e = self.mkLambda(lam.binderName, newtype, newbody);
                return new_e;
            },
            .forallE => |pi| {
                const newtype = self.replace_rec(ctx, pi.binderType, f, offset);
                const newbody = self.replace_rec(ctx, pi.body, f, offset + 1);
                if (newtype == pi.binderType and newbody == pi.body) return e;
                const new_e = self.mkForallE(pi.binderName, newtype, newbody);
                return new_e;
            }
        }
    }

    /// Substitute loose (unbound) bvars in `e` with target expressions.
    /// Typically `e` will be the body of some binder.
    /// Start substituting at de Brujin index `startIdx` (counting only unbound bvars).
    /// Indices past the substitution window are adjusted downward to account for resolved binders
    pub fn substLooseBvars(self: *Self, e: Expr, startIdx: Idx, subst: []const Expr) Expr {
        if (subst.len == 0) return e;
        if (self.em.getLooseBvarRange(e) <= startIdx) return e;
        const SubstCtx = struct {
            const Ctx = @This();
            store: *Self,
            startIdx: Idx,
            subst: []const Expr,
            // Called on every subexpression
            fn visit(c: anytype, sube: Expr, binderDepth: u32) ?Expr {
                const ctx: Ctx = c;
                const es = ctx.store;
                const em = es.em;
                const localStartIdx = ctx.startIdx + binderDepth;
                if (em.getLooseBvarRange(sube) <= localStartIdx) {
                    // No more loose bvars to capture in this subtree
                    return sube; // Stop visiting this subtree
                }
                if (localStartIdx < ctx.startIdx) {
                    // u32 overflow means there can't be anything left to do
                    return sube;
                }
                if (!sube.isBvar()) return null;
                const bvarId = sube.bvarId();
                if (bvarId < localStartIdx) {
                    // This bvar is before the substitution window, no change needed
                    return null;
                }
                const end = localStartIdx + ctx.subst.len;
                if (bvarId < end) {
                    // Substitute this bvar, first need to lift its bvars
                    std.debug.assert(bvarId >= localStartIdx);
                    return es.liftLooseBvars(ctx.subst[bvarId - localStartIdx], 0, binderDepth);
                } else {
                    // This bvar is past the substitution window, adjust index
                    return es.mkBvar(@intCast(bvarId - ctx.subst.len));
                }
            }
        };
        const context: SubstCtx = .{ .store = self, 
            .startIdx = startIdx, .subst = subst };
        return self.replace(context, e, SubstCtx.visit);
    }

    
    /// Add specified offset to loose bvars in the target expression.
    /// Return modified expression.
    pub fn liftLooseBvars(self: *Self, e: Expr, startIdx: Idx, offset: Idx) Expr {
        if (offset == 0) return e;
        if (self.em.getLooseBvarRange(e) <= startIdx) return e;
        const LiftCtx = struct {
            const Ctx = @This();
            store: *Self,
            startIdx: Idx,
            offset: Idx,
            fn visit(c: anytype, sube: Expr, binderDepth: u32) ?Expr {
                const ctx: Ctx = c;
                const em = ctx.store.em;
                const localStartIdx = ctx.startIdx + binderDepth;
                if (em.getLooseBvarRange(sube) <= localStartIdx) return sube;
                if (localStartIdx < ctx.startIdx) return sube; // overflow
                if (!sube.isBvar()) return null;
                const bvarId = sube.bvarId();
                if (bvarId < localStartIdx) return null;
                return ctx.store.mkBvar(bvarId + ctx.offset);
            }
        };
        const context: LiftCtx = .{ .store = self, .startIdx = startIdx, .offset = offset };
        return self.replace(context, e, LiftCtx.visit);
    }

    /// Substitute universe level parameters into an expression by fully traversing it.
    pub fn substLevelParams(self: *Self, e: Expr, names: []const Name, levels: []const Level) Expr {
        _ = self;
        _ = e;
        _ = names;
        _ = levels;
        @panic("universe level substitution into expressions not yet implemented");
    }

};
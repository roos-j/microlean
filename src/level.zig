const std = @import("std");
const Name = @import("common.zig").Name;
const Buffer = @import("common.zig").Buffer;
const oom = @import("common.zig").oom;

// Universe level
pub const Level = u32; // 28 bits so that Expr fits in 64 bits

pub const LevelMax = struct { lhs: Level, rhs: Level };

pub const LevelKind = enum { zero, succ, max, param };

pub const level_zero: Level = 0;
pub const level_one: Level = 1;

pub const LevelContent = union(LevelKind) {
    zero: void,
    succ: Level,
    max: LevelMax,
    param: Name,

    pub inline fn kind(self: LevelContent) LevelKind {
        return std.meta.activeTag(self);
    }
};

// Optimizations to add later: normalization, has_param, depth, explicit_offset
pub const LevelNode = struct { 
    content: LevelContent, 
    depth: u32, 
    offset_base: Level, 
    offset: u32,
    has_param: bool, 
    is_explicit: bool
};

pub const LevelOffset = struct { lvl: Level, offset: u32 };

pub const LevelManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    nodes: std.ArrayList(LevelNode) = .empty,
    hash_map: std.AutoHashMap(LevelContent, Level),

    const GetOrPutResult = std.AutoHashMap(LevelContent, Level).GetOrPutResult;

    pub fn create(allocator: std.mem.Allocator) *LevelManager {
        const self = allocator.create(LevelManager) catch oom();
        self.* = .{ .allocator = allocator, .hash_map = .init(allocator) };
        self.initZeroOne();
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.nodes.deinit(self.allocator);
        self.hash_map.deinit();
        self.allocator.destroy(self);
    }

    fn initZeroOne(self: *Self) void {
        const zero: LevelNode = .{ .content = .zero, .depth = 0, .has_param = false, .offset = 0, .offset_base = 0, .is_explicit = true };
        const one: LevelNode = .{ .content = .{ .succ = 0 }, .depth = 1, .has_param = false, .offset = 1, .offset_base = 0, .is_explicit = true };
        self.insertNode(zero);
        self.insertNode(one);
        // We don't add these to hash map
    }

    // Todo: refactor
    fn cache(self: *Self, content: LevelContent) GetOrPutResult {
        std.debug.assert(content.kind() != .zero);
        std.debug.assert(!(content.kind() == .succ and content.succ == 0));
        const result = self.hash_map.getOrPut(content) catch oom();
        if (result.found_existing) {
            return result;
        }
        if (self.nodes.items.len >= std.math.maxInt(Level)) {
            @panic("maximum number of stored universe levels exceeded");
        }
        const new_id: Level = @intCast(self.nodes.items.len);
        result.value_ptr.* = new_id;
        // does not append node to nodes array yet!
        return result;
    }

    inline fn insertNode(self: *Self, node: LevelNode) void {
        self.nodes.append(self.allocator, node) catch oom();
    }

    pub fn getNode(self: *const Self, lvl: Level) LevelNode {
        return self.nodes.items[lvl];
    }

    pub fn get(self: *const Self, lvl: Level) LevelContent {
        return self.nodes.items[lvl].content;
    }

    pub fn hasParam(self: *const Self, lvl: Level) bool {
        return self.getNode(lvl).has_param;
    }

    pub fn isExplicit(self: *const Self, lvl: Level) bool {
        return self.getNode(lvl).is_explicit;
    }

    pub fn getDepth(self: *const Self, lvl: Level) u32 {
        return self.getNode(lvl).depth;
    }

    pub fn getOffset(self: *const Self, lvl: Level) u32 {
        return self.getNode(lvl).offset;
    }

    pub fn getOffsetBase(self: *const Self, lvl: Level) Level {
        return self.getNode(lvl).offset_base;
    }

    pub fn getOffsetBaseKind(self: *const Self, lvl: Level) LevelKind {
        return self.get(self.getNode(lvl).offset_base).kind();
    }

    pub fn mkZero(self: *Self) Level {
        _ = self;
        return 0;
    }

    pub fn mkOne(self: *Self) Level {
        _ = self;
        return 1;
    }

    pub fn mkSucc(self: *Self, lvl: Level) Level {
        if (lvl == 0) return 1;
        const content: LevelContent = .{ .succ = lvl };
        const result = self.cache(content);
        const id: Level = result.value_ptr.*;
        if (result.found_existing) return id;
        // Compute metacontent for new node
        const node: LevelNode = .{ .content = content, 
            .depth = self.getDepth(lvl)+1, .has_param = self.hasParam(lvl), 
            .offset_base = self.getOffsetBase(lvl), 
            .offset = self.getOffset(lvl)+1,
            .is_explicit = self.isExplicit(lvl) };
        self.insertNode(node);
        return id;
    }

    pub fn mkMax(self: *Self, lhs: Level, rhs: Level) Level {
        if (self.isExplicit(lhs) and self.isExplicit(rhs)) {
            return if (self.getOffset(lhs) >= self.getOffset(rhs)) lhs else rhs;
        } else if (lhs == 0) {
            return rhs;
        } else if (rhs == 0) {
            return lhs;
        } else if (lhs == rhs) {
            return lhs;
        }
        // Todo: add more simplifications
        const content: LevelContent = .{ .max = .{ .lhs = lhs, .rhs = rhs } };
        const result = self.cache(content);
        const id: Level = result.value_ptr.*;
        if (result.found_existing) {
            return id;
        }
        const node: LevelNode = .{ .content = content,
            .depth = @max(self.getDepth(lhs), self.getDepth(rhs)) + 1, 
            .has_param = self.hasParam(lhs) or self.hasParam(rhs),
            .offset = 0,
            .offset_base = id,
            .is_explicit = false};
        self.insertNode(node);
        return id;
    }

    pub fn mkParam(self: *Self, name: Name) Level {
        const content: LevelContent = .{ .param = name };
        const result = self.cache(content);
        const id: Level = result.value_ptr.*;
        if (result.found_existing) {
            return id;
        }
        const node: LevelNode = .{ .content = content,
            .depth = 0, .has_param = true,
            .offset = 0, .offset_base = id,
            .is_explicit = false };
        self.insertNode(node);
        return id;
    }

    pub fn printLevel(self: *const Self, lvl: Level) void {
        const node = self.getNode(lvl);
        if (node.is_explicit) {
            std.debug.print("{d}", .{node.offset});
            return;
        }
        const content = self.get(node.offset_base);
        switch (content) {
            .zero, .succ => unreachable,
            .max => |m| {
                std.debug.print("max(", .{});
                self.printLevel(m.lhs);
                std.debug.print(", ", .{});
                self.printLevel(m.rhs);
                std.debug.print(")", .{});
            },
            .param => |p| {
                std.debug.print("param({})", .{p});
            },
        }
        if (node.offset > 0) {
            std.debug.print("+{d}", .{node.offset});
        }
    }

    pub fn printAllNodes(self: *const Self) void {
        for (self.nodes.items, 0..) |_, id| {
            std.debug.print("node {d}: ", .{id});
            self.printLevel(@intCast(id));
            std.debug.print("\n", .{});
        }
    }

    pub fn equal(self: *const Self, l1: Level, l2: Level) bool {
        if (l1 == l2) return true; // This should already take care of many `true`s
        if (self.isExplicit(l1) or self.isExplicit(l2)) {
            // If both explicit and equal, then they should have equal id
            std.debug.assert(!self.isExplicit(l1) or !self.isExplicit(l2) or self.getOffset(l1) != self.getOffset(l2));
            return false; 
        }
        // This is not exhaustive for now. Todo: complete normalization if necessary
        if (self.getOffset(l1) != self.getOffset(l2)) return false;
        if (self.getOffsetBaseKind(l1) != self.getOffsetBaseKind(l2)) return false;
        // Detect equality for levels of the form `param(n)+offset`
        std.debug.assert(self.getOffset(l1) == self.getOffset(l2));
        if (self.getOffsetBaseKind(l1) == .param and self.getOffsetBaseKind(l2) == .param) return self.getOffsetBase(l1) == self.getOffsetBase(l2);
        @panic("Level equality not fully implemented yet.");
    }

    /// Replace specified level parameters with the specified values
    pub fn instantiate(self: *Self, l: Level, names: []Name, lvls: []Level) Level {
        if (self.hasParam(l)) {
            @panic("Level instantiation not yet implemented!");
        }
        _ = names;
        _ = lvls;
        return l;
    }

};

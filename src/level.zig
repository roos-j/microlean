const std = @import("std");
const NameId = @import("common.zig").NameId;
const oom = @import("common.zig").oom;

// Universe level
pub const Level = u32;

pub const LevelMax = struct { lhs: Level, rhs: Level };

pub const LevelKind = enum { zero, succ, max, param };

pub const level_zero: Level = 0;
pub const level_one: Level = 1;

pub const LevelData = union(LevelKind) {
    zero: void,
    succ: Level,
    max: LevelMax,
    param: NameId,

    pub inline fn kind(self: LevelData) LevelKind {
        return std.meta.activeTag(self);
    }
};

// Optimizations to add later: normalization, has_param, depth, explicit_offset
pub const LevelNode = struct { 
    data: LevelData, 
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
    hash_map: std.AutoHashMap(LevelData, Level),

    const GetOrPutResult = std.AutoHashMap(LevelData, Level).GetOrPutResult;

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self: Self = .{ .allocator = allocator, .hash_map = .init(allocator) };
        self.initZeroOne();
        return self;
    }

    fn initZeroOne(self: *Self) void {
        const zero: LevelNode = .{ .data = .zero, .depth = 0, .has_param = false, .offset = 0, .offset_base = 0, .is_explicit = true };
        const one: LevelNode = .{ .data = .{ .succ = 0 }, .depth = 1, .has_param = false, .offset = 1, .offset_base = 0, .is_explicit = true };
        self.insertNode(zero);
        self.insertNode(one);
        // We don't add these to hash map
    }

    fn cache(self: *Self, data: LevelData) GetOrPutResult {
        std.debug.assert(data.kind() != .zero);
        std.debug.assert(!(data.kind() == .succ and data.succ == 0));
        const result = self.hash_map.getOrPut(data) catch oom();
        if (result.found_existing) {
            return result;
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

    pub fn get(self: *const Self, lvl: Level) LevelData {
        return self.nodes.items[lvl].data;
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
        const data: LevelData = .{ .succ = lvl };
        const result = self.cache(data);
        const id: Level = result.value_ptr.*;
        if (result.found_existing) return id;
        // Compute metadata for new node
        const node: LevelNode = .{ .data = data, 
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
        const data: LevelData = .{ .max = .{ .lhs = lhs, .rhs = rhs } };
        const result = self.cache(data);
        const id: Level = result.value_ptr.*;
        if (result.found_existing) {
            return id;
        }
        const node: LevelNode = .{ .data = data,
            .depth = @max(self.getDepth(lhs), self.getDepth(rhs)) + 1, 
            .has_param = self.hasParam(lhs) or self.hasParam(rhs),
            .offset = 0,
            .offset_base = id,
            .is_explicit = false};
        self.insertNode(node);
        return id;
    }

    pub fn mkParam(self: *Self, name: NameId) Level {
        const data: LevelData = .{ .param = name };
        const result = self.cache(data);
        const id: Level = result.value_ptr.*;
        if (result.found_existing) {
            return id;
        }
        const node: LevelNode = .{ .data = data,
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
        const data = self.get(node.offset_base);
        switch (data) {
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

};

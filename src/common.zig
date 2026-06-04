const std = @import("std");

pub fn oom() noreturn {
    @panic("out of memory");
}

// pub const Name = []const u8;

pub const Name = u32;

/// Wrapper for an array list with an allocator and panic on out of memory.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        list: std.ArrayList(T) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.list.deinit(self.allocator);
        }

        pub fn append(self: *Self, item: T) void {
            self.list.append(self.allocator, item) catch oom();
        }

        pub fn pop(self: *Self) ?T {
            return self.list.pop();
        }

        pub fn len(self: *const Self) usize {
            return self.list.items.len;
        }

        /// Clear buffer retaining capacity
        pub fn clear(self: *Self) void {
            self.list.clearRetainingCapacity();
        }

        /// Get item at specified index. No bounds check performed.
        pub fn get(self: *const Self, i: usize) T {
            return self.list.items[i];
        }

        pub fn items(self: *const Self) []T {
            return self.list.items;
        }
    };
}
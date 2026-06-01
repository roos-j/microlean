pub fn oom() noreturn {
    @panic("out of memory");
}

// pub const Name = []const u8;

pub const NameId = u32;

// pub fn CachedStore(comptime Id: type, comptime Data: type) type 
//     return struct {
//         const Self = @This();

//         pub const Node = struct { data: Data };

//         allocator: std.mem.Allocator,
//         nodes: std.ArrayList(Node) = .empty,
//         hash_map: std.AutoHashMap(Data, Id),

//         pub fn init(allocator: std.mem.Allocator) Self {
//             return .{ .allocator = allocator, .hash_map = .init(allocator) };
//         }

//         pub fn insert(self: *Self, data: Data) !Id {
//             const result = try self.hash_map.getOrPut(data);
//             if (result.found_existing) {
//                 return result.value_ptr.*;
//             } else {
//                 const id: Id = @intCast(self.nodes.items.len);
//                 try self.nodes.append(self.allocator, .{ .data = data });
//                 result.value_ptr.* = id;
//                 return id;
//             }
//         }

//         pub fn get(self: *const Self, id: Id) Data {
//             return self.nodes.items[@intCast(id)].data;
//         }
//     };
// }

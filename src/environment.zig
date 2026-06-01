const std = @import("std");
const Name = @import("common.zig").Name;
const Expr = @import("expr.zig").Expr;

// ToDo: add thmDecl, inductDecl
// Omit: opaqueDecl, quotDecl, mutualDefnDecl
pub const DeclarationKind = enum { axiomDecl, defnDecl };

pub const AxiomVal = struct {
    name: Name,
    levelParams: []const Name,
    type: Expr
};

pub const DefinitionVal = struct {
    name: Name,
    levelParams: []const Name,
    type: Expr,
    value: Expr
};

pub const DeclarationContent = union(DeclarationKind) {
    axiomDecl: AxiomVal,
    defnDecl: DefinitionVal
};

// // Add later: thmInfo, inductInfo, ctorInfo, recInfo
// // Omit: opaqueInfo, quotInfo
// pub const ConstantInfoKind = enum { axiomInfo, defnInfo };

// pub const ConstantInfoContent = union(ConstantInfoKind) {
//     axiomInfo: AxiomVal,
//     defnInfo: DefinitionVal
// };

pub const Environment = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    declarations: std.hash_map.AutoHashMap(Name, DeclarationContent),

    pub fn init(allocator: std.mem.Allocator) Self {
        const self: Self = .{ .allocator = allocator, .hash_map = .init(allocator) };
        return self;
    }

    pub fn find(self: *const Self, name: Name) ?DeclarationContent {
        return self.declarations.get(name);
    }

    // /// Add a checked declaration to the environment
    // pub fn add(self: *Self, name: Name, certified_decl: DeclarationContent) !void {
    //     if (self.declarations.contains(name)) {
    //     }
    // }   

};
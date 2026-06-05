const std = @import("std");
const Name = @import("common.zig").Name;
const Expr = @import("expr.zig").Expr;

pub const AxiomVal = struct {
    name: Name,
    levelParams: []const Name,
    type: Expr
};

pub const DefinitionVal = struct {
    name: Name,
    levelParams: []const Name,
    type: Expr,
    value: ?Expr,

    pub inline fn hasValue(self: DefinitionVal) bool {
        return self.value != null;
    }

    pub inline fn getValue(self: DefinitionVal) Expr {
        std.debug.assert(self.hasValue());
        return self.value.?;
    }
};

// ToDo: add thmDecl, inductDecl
// Omit: opaqueDecl, quotDecl, mutualDefnDecl
pub const DeclarationKind = enum { axiomDecl, defnDecl };

/// Declarations are for submitting declarations to the environment
/// which are then usually type checked.
pub const Declaration = union(DeclarationKind) {
    axiomDecl: AxiomVal,
    defnDecl: DefinitionVal
};

// Missing: thmInfo, opaqueInfo, quotInfo, inductInfo, ctorInfo, recInfo
pub const ConstantInfoKind = enum { axiomInfo, defnInfo };

/// ConstantInfo is for already added declarations in the environment
pub const ConstantInfo = union(ConstantInfoKind) {
    axiomInfo: AxiomVal,
    defnInfo: DefinitionVal,

    pub inline fn hasValue(info: ConstantInfo) bool {
        return switch (info) {
            .axiomInfo => false,
            .defnInfo => |val| val.hasValue()
        };
    }

    pub inline fn getValue(info: ConstantInfo) Expr {
        std.debug.assert(info.hasValue());
        switch (info) {
            .axiomInfo => unreachable,
            .defnInfo => |val| return val.getValue()
        }
    }

    pub inline fn getLevelParams(info: ConstantInfo) []const Name {
        return switch (info) {
            .axiomInfo => |val| val.levelParams,
            .defnInfo => |val| val.levelParams
        };
    }

    pub inline fn getNumLevelParams(info: ConstantInfo) u32 {
        return info.getLevelParams().len;
    }

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
    constants: std.hash_map.AutoHashMap(Name, ConstantInfo),

    pub fn init(allocator: std.mem.Allocator) Self {
        const self: Self = .{ .allocator = allocator, 
            .constants = .init(allocator) };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.constants.deinit();
    }

    pub fn find(self: *const Self, name: Name) ?ConstantInfo {
        return self.constants.get(name);
    }

    // /// Add a checked declaration to the environment
    // pub fn add(self: *Self, name: Name, certified_decl: DeclarationContent) !void {
    //     if (self.declarations.contains(name)) {
    //     }
    // }   

};
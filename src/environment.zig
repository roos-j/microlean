const std = @import("std");
const builtin = @import("builtin");
const Name = @import("common.zig").Name;
const oom = @import("common.zig").oom;
const Expr = @import("expr.zig").Expr;
const ExprStore = @import("expr.zig").ExprStore;
const ExprManager = @import("expr.zig").ExprManager;
const KernelError = @import("type_checker.zig").KernelError;
const TypeChecker = @import("type_checker.zig").TypeChecker;

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


    pub inline fn getName(info: ConstantInfo) Name {
        return switch (info) {
            .axiomInfo => |val| val.name,
            .defnInfo => |val| val.name
        };
    }

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
        return @intCast(info.getLevelParams().len);
    }

    pub inline fn getType(info: ConstantInfo) Expr {
        return switch (info) {
            .axiomInfo => |val| val.type,
            .defnInfo => |val| val.type
        };
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
    lastName: Name, // Tracks the constant name that was last assigned
    em: *ExprManager,

    pub fn create(allocator: std.mem.Allocator, em: *ExprManager) *Self {
        const self = allocator.create(Environment) catch oom();
        // TODO: Streamline interdependencies
        self.* = .{ .allocator = allocator, 
            .constants = .init(allocator),
            .em = em,
            .lastName = 0 };
        return self;
    }

    // Make an unused constant name, incrementing internal counter.
    pub fn mkFreshName(self: *Self) Name {
        self.lastName += 1;
        return self.lastName;
    }

    pub fn destroy(self: *Self) void {
        self.constants.deinit();
        self.allocator.destroy(self);
    }

    pub fn find(self: *const Self, name: Name) ?ConstantInfo {
        return self.constants.get(name);
    }

    /// Add a constant to the environment without type checking (debug only).
    /// Will replace existing constant if existing already.
    pub fn addUnchecked(self: *Self, name: Name, level_params: []const Name, typ: Expr, value: Expr) void {
        if (builtin.mode != .Debug) {
            @panic("addUnchecked only for debugging");
        }
        const info: ConstantInfo = .{ .defnInfo = .{ .name = name,
            .levelParams = level_params, .type = typ, .value = value } };
        self.constants.put(name, info) catch oom();
    } 

    /// Add an axiom to the environment.
    pub fn addAxiom(self: *Self, name: Name, level_params: []const Name, typ: Expr) KernelError!void {
        const info: ConstantInfo = .{ .axiomInfo = .{ .name = name, .levelParams = level_params, .type = typ } };
        try self.checkAxiom(typ);
        self.constants.put(name, info) catch oom();   
    }

    /// Type-check and add a declaration to the environment. If no type is provided, it is inferred.
    pub fn add(self: *Self, name: Name, level_params: []const Name, typ: ?Expr, value: Expr) KernelError!void {
        if (self.constants.contains(name)) {
            return KernelError.ConstantAlreadyDeclared;
        }
        const t = try self.checkConstant(typ, value);
        const info: ConstantInfo = .{ .defnInfo = .{ .name = name,
            .levelParams = level_params, .type = t, .value = value } };
        self.constants.put(name, info) catch oom();
    }

    /// Unpack a `ConstantInfo` and call `add` or `addAxiom`
    pub fn addConstant(self: *Self, info: ConstantInfo) KernelError!void {
        switch (info) {
            .axiomInfo => try self.addAxiom(info.axiomInfo.name, info.axiomInfo.levelParams, info.axiomInfo.type),
            .defnInfo => try self.add(info.defnInfo.name, info.defnInfo.levelParams, info.defnInfo.type, info.defnInfo.value)
        }
    }    

    /// Type-check a proposed axiom.
    fn checkAxiom(self: *Self, typ: Expr) KernelError!void {
        const tc: *TypeChecker = .create(self.allocator, self.em, self.em.getGlobalStore(), self);
        defer tc.destroy();
        const type_type = try tc.checkType(typ);
        _ = try tc.ensureSort(type_type);
    }

    /// Type-check a proposed constant before adding it to the environment.
    /// Return declared type, or inferred type if no declared type.
    fn checkConstant(self: *Self, typ: ?Expr, value: Expr) KernelError!Expr {
        // TODO: Make temporary stores work - expr's that are part of declaration need to be promoted
        // const ts: ExprStore = self.em.createStore();
        // defer self.em.closeStore(ts.storeId);
        const tc: *TypeChecker = .create(self.allocator, self.em, self.em.getGlobalStore(), self);
        defer tc.destroy();
        // check that declared value has a well-defined type
        const val_type = try tc.checkType(value);
        if (typ) |decl_type| {
            // check that declared type is a well-formed type
            const type_type = try tc.checkType(decl_type);
            _ = try tc.ensureSort(type_type);
            // check that declared type matches inferred type
            if (!(try tc.isDefEq(decl_type, val_type))) {
                return KernelError.DeclTypeMismatch;
            }
            return decl_type;
        } else {
            return val_type;
        }
    }

};
const std = @import("std");
const oom = @import("common.zig").oom;
const Buffer = @import("common.zig").Buffer;

const Lexer = @import("lexer.zig").Lexer;
const Token = @import("lexer.zig").Token;
const Expr = @import("expr.zig").Expr;
const LevelManager = @import("level.zig").LevelManager;
const Level = @import("level.zig").Level;

/// Parser for MicroLean
/// We implement a simple recursive descent parser.
/// Almost LL(1) grammar (except for arbitrary identifier look ahead):
///
/// file -> command*
/// command -> declaration | cmd
/// cmd -> "#check" term
/// declaration -> "axiom" IDENT ':' term | "def" IDENT (":" term)? ":=" term | "universe" IDENT | "import" IDENT
///
/// term -> lambda | funType | sort
/// 
/// sort -> "Sort" level | "Prop"
/// level -> ident | "max" level level | "imax" level level | NUMLIT | level "+" NUMLIT | "(" level ")"
///
/// lambda -> "fun" binder "=>" term
/// binder -> parenBinder+ | noParenBinder
/// parenBinder -> "(" IDENT+ (":" term)? ")"
/// noParenBinder -> IDENT+ (":" term)?
/// 
/// funType -> indepFunType | depFunType
/// indepFunType -> app "->" funType
/// 
/// app -> atom+
/// atom -> ident | "(" term ")"
/// 
/// 
pub const TermKind = enum(u3) {
    lambda,
    pi,
    sort,
    ident,
    numlit,
};

pub const Term = packed struct {
    kind: TermKind,
    id: u32
};

/// A slice of the original source code
pub const Slice = packed struct {
    start: usize, // Start index
    end: usize, // End index

    pub fn len(self: Slice) usize {
        return self.end - self.start + 1;
    }
};

pub const TermContent = union(TermKind) {
    lambda: TermBinder,
    pi: TermBinder,
    app: TermApp,
    sort: TermLevel,
    ident: Slice,
    numlit: u64, // Actual Lean has no size restriction here
};

pub const TermNode = struct {
    content: TermContent,
    slice: Slice,
};

pub const TermApp = struct {
    fun: Term,
    arg: Term
};

pub const TermBinder = struct {
    binderName: Slice,
    binderType: Term,
    body: Term
};

/// We reuse the kernel code for universe levels for Level terms
pub const TermLevel = Level;

pub const Parser = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    src: []const u8,
    lx: *Lexer,
    terms: Buffer(TermNode) = undefined,
    lm: *LevelManager = undefined, // Parser's LevelManager is separate from kernel's LevelManager

    pub fn create(allocator: std.mem.Allocator, src: []const u8) *Parser {
        const self = allocator.create(Parser) catch oom();
        self.* = .{ .allocator = allocator, 
            .arena = .init(allocator), .src = src,
            .lx = undefined };
        self.lx = .init(self.arena, src);
        self.terms = .init(self.arena);
        self.lm = .create(self.arena);
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    // fn level(self: *Self) Term {
    //     const t = self.lx.lookahead(0);

    // } 

};
const std = @import("std");
const oom = @import("common.zig").oom;
const Buffer = @import("common.zig").Buffer;
const Name = @import("common.zig").Name;

const Lexer = @import("lexer.zig").Lexer;
const Token = @import("lexer.zig").Token;
const TokenKind = @import("lexer.zig").TokenKind;
const Expr = @import("expr.zig").Expr;
const LevelManager = @import("level.zig").LevelManager;
const Level = @import("level.zig").Level;

pub const ParserError = error {
    SyntaxError,
};

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
    len: usize, // Length of slice

    /// Return the string corresponding to this slice. Assume slice is well-formed.
    pub fn get(self: Slice, lx: *Lexer) []const u8 {
        return lx.src[self.start..self.start+self.len];
    }

    pub fn fromToken(t: Token) Slice {
        return .{ .start = t.source_offset+t.offset, .len = t.len-t.offset };
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
    lx: *Lexer = undefined,
    terms: Buffer(TermNode) = undefined,
    lm: *LevelManager = undefined, // Parser's LevelManager is separate from kernel's LevelManager
    level_idents: std.StringHashMap(Name) = undefined,

    pub fn create(allocator: std.mem.Allocator, src: []const u8) *Parser {
        const self = allocator.create(Parser) catch oom();
        self.* = .{ .allocator = allocator, 
            .arena = .init(allocator), .src = src };
        self.lx = .init(self.arena, src);
        self.terms = .init(self.arena);
        self.lm = .create(self.arena);
        self.level_idents = .init(self.arena); 
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    /// Consume and return next token, checking if it is of prescribed kind.
    fn expect(self: *Self, comptime expected: anytype) ParserError!Token {
        const t = self.lx.next();
        if (@TypeOf(expected) == TokenKind) {
            if (t.kind == expected) return t;
            const line = self.lx.lineNumber(t.source_offset);
            std.debug.print("l. {d}: expected {s}, found {s}\n", .{line, @tagName(expected), @tagName(t.kind)});
            return ParserError.SyntaxError;
        }
        // Assume expected is an iterable over TokenKind
        inline for (expected) |kind|
            if (t.kind == kind) return t;
        const line = self.lx.lineNumber(t.source_offset);
        std.debug.print("l. {d}: expected one of {{", .{line});
        inline for (expected) |kind|
            std.debug.print("{s} ", .{@tagName(kind)});
        std.debug.print("}}, found {s}\n", .{@tagName(t.kind)});
        return ParserError.SyntaxError;
    }

    /// level -> levelAtom ("+" NUMLIT)
    fn level(self: *Self) ParserError!Level {
        const lvl = try self.levelAtom();
        if (self.lx.lookahead(0).kind == .plus) {
            _ = self.lx.next();
            const offset_t = try self.expect(.numlit);
            const offset = try offset_t.numlitValue(self.lx, u32);
            return self.lm.mkOffset(lvl, offset);
        } else return lvl;
    }

    fn identToLevelName(self: *Self, ident: []const u8) Name {
        const res = self.level_idents.getOrPut(ident) catch oom();
        if (res.found_existing) return res.value_ptr.*
        else {
            const new_name: Name = self.level_idents.count(); // both u32
            res.value_ptr.* = new_name;
            return new_name;
        }
    }

    /// levelAtom -> ident | "max" levelAtom levelAtom | "imax" levelAtom levelAtom | NUMLIT | "(" level ")"
    fn levelAtom(self: *Self) ParserError!Level {
        const t = try self.expect(.{ .ident, .max, .imax, .numlit, .lparen });
        switch (t.kind) {
            .ident => return self.lm.mkParam(self.identToLevelName(t.token(self.lx))),
            .max => return self.lm.mkMax(try self.levelAtom(), try self.levelAtom()),
            .imax => return self.lm.mkIMax(try self.levelAtom(), try self.levelAtom()),
            .numlit => return self.lm.mkExplicit(try t.numlitValue(self.lx, u32)),
            .lparen => {
                const res = try self.level();
                _ = try self.expect(.rparen);
                return res;
            }
        }
    }

};
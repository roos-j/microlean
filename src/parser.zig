const std = @import("std");
const oom = @import("common.zig").oom;
const Buffer = @import("common.zig").Buffer;
const Pair = @import("common.zig").Pair;
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
/// 
///
/// fun x: fun y:B => 
/// 
/// 
/// 
pub const TermKind = enum(u3) {
    app,
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
    ident: Name
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
    binderName: Name,
    binderType: ?Term,
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
    idents: std.StringHashMap(Name) = undefined,

    pub fn create(allocator: std.mem.Allocator, src: []const u8) *Parser {
        const self = allocator.create(Parser) catch oom();
        self.* = .{ .allocator = allocator, 
            .arena = .init(allocator), .src = src };
        self.lx = self.arena.allocator().create(Lexer) catch oom();
        self.lx.* = .init(self.arena.allocator(), src);
        self.terms = .init(self.arena.allocator());
        self.lm = .create(self.arena.allocator());
        self.idents = .init(self.arena.allocator()); 
        self.idents.put("_", 0) catch oom(); // hard-code anonymous identifier
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

    /// `term -> lambda | funType`
    fn term(self: *Self) ParserError!Term {
        const t = self.lx.lookahead(0);
        switch (t.kind) {
            .lambda => return try self.lambda(),
            else => return try self.funType()
        }
    }

    /// `lambda -> "fun" binder "=>" term`
    /// 
    /// `binder -> parenBinder+ | noParenBinder`
    /// 
    /// `parenBinder -> "(" IDENT+ (":" term)? ")"`
    /// 
    /// `noParenBinder -> IDENT+ (":" term)?`
    fn lambda(self: *Self) ParserError!Term {
        _ = try self.expect(.lambda);
        var t = self.lx.lookahead(0);

        const idents: Buffer(Token) = .init(self.arena.allocator());
        defer idents.deinit();
        const types: Buffer(Pair(?Term, usize)) = .init(self.arena.allocator());
        defer types.deinit();
 
        if (t.kind != .lparen) { // noParenBinder
            try self.binderDesc(&idents, &types);
        } else { // parenBinder
            while (t.kind == .lparen) { // parenBinder
                _ = try self.expect(.lparen);
                try self.binderDesc(&idents, &types);
                _ = try self.expect(.rparen);
                t = self.lx.lookahead(0);
            }
        }
        // "=>" term
        _ = try self.expect(.mapsto);
        var body = try self.term();
        // Build lambda terms
        std.debug.assert(types.len() > 0);
        while (types.len() > 0) {
            const cur_type_p = types.pop() orelse unreachable;
            std.debug.assert(cur_type_p.snd > 0);
            for (0..cur_type_p.snd) |_| {
                const ident = idents.pop() orelse unreachable;
                std.debug.assert(ident.kind == .ident);
                body = self.mkLambda(ident, cur_type_p.fst, body);
            }
        }
        return body;
    }

    /// `IDENT+ (":" term)?`
    fn binderDesc(self: *Self, idents: *Buffer(Token), types: *Buffer(Pair(?Term, usize))) ParserError!void {
        var cnt: usize = 0;
        var tk = try self.expect(.ident);
        while (true) {
            idents.append(tk);
            cnt += 1;
            tk = self.lx.lookahead(0);
            if (tk.kind != .ident) break
            else tk = try self.lx.next();
        }
        if (tk.kind == .colon) types.append(.mk(try self.varType(), cnt))
        else types.append(.mk(null, cnt));
    }

    /// `":" term`
    fn varType(self: *Self) ParserError!Term {
        _ = try self.expect(.colon);
        return try self.term();
    }

    /// `funType -> indepFunType | depFunType`
    /// 
    /// `indepFunType -> app ("->" funType)`
    /// 
    /// `depFunType -> parenBinder "->" funType`
    fn funType(self: *Self) ParserError!Term {
        var tk = self.lx.lookahead(0);
        if (tk.kind == .lparen) {
            // Check if this is a dependent function type
            // Look ahead through idents until ":" found
            var i: usize = 1;
            while (self.lx.lookahead(i).kind == .ident) i += 1;
            if (self.lx.lookahead(i).kind == .colon) { // depFunType
                _ = try self.expect(.lparen);
                const idents: Buffer(Token) = .init(self.arena.allocator());
                defer idents.deinit();
                const types: Buffer(Pair(?Term, usize)) = .init(self.arena.allocator());
                defer types.deinit();
                try self.binderDesc(&idents, &types);
                _ = try self.expect(.rparen);
                _ = try self.expect(.to);
                var body = try self.funType();
                std.debug.assert(types.len() == 1);
                std.debug.assert(types.get(0).snd == idents.len());
                std.debug.assert(types.get(0).fst != null);
                std.debug.assert(idents.len() > 0);
                for (0..idents.len()) |_| {
                    const id_tk = idents.pop() orelse unreachable;
                    body = self.mkPi(id_tk, self.identToName(id_tk.token(self.lx)), types.get(0).fst, body);
                }
                return body;
            }
        }
        // indepFunType
        const head = try self.app();
        tk = try self.lx.lookahead(0);
        if (tk.kind == .to) {
            const body = try self.funType();
            return self.mkPi(tk, 0, head, body);
        } else {
            return head;
        }
    }

    /// `app -> atom+`
    fn app(self: *Self) ParserError!Term { 
        // parse `f a b` as `app (app f a) b`
        var fun = try self.atom();
        while (true) {
            const t = self.lx.lookahead(0);
            switch (t.kind) {
                .ident, .sort, .prop, .lparen => fun = self.mkApp(t, fun, try self.atom()),
                else => break
            }
        }
        return fun;
    }

    /// `atom -> IDENT | sort | "(" term ")"`
    /// 
    /// `sort -> "Sort" level | "Prop"`
    fn atom(self: *Self) ParserError!Term {
        const t = try self.expect(.{.ident, .sort, .prop, .lparen});
        switch (t.kind) {
            .ident => return self.mkIdent(t),
            .sort => {
                const lvl = try self.level();
                return self.mkSort(t, lvl);
            },
            .prop => return self.mkSort(t, self.lm.mkZero()),
            .lparen => {
                const tk = try self.term();
                _ = try self.expect(.rparen);
                return tk;
            },
            else => unreachable
        }
    }

    inline fn addTerm(self: *Self, t: Token, content: TermContent) Term {
        const node: TermNode = .{ .content = content, .slice = .fromToken(t) };
        const rv: Term = .{ .id = self.terms.len(), .kind = std.meta.activeTag(node.content) };
        self.terms.append(node);
        return rv;
    }

    fn mkIdent(self: *Self, t: Token) Term {
        std.debug.assert(t.kind == .ident);
        const n = self.identToName(t.token(self.lx));
        const content: TermContent = .{ .ident = n };
        return self.addTerm(t, content);
    }

    fn mkSort(self: *Self, t: Token, lvl: Level) Term {
        std.debug.assert(t.kind == .sort or t.kind == .prop);
        const content: TermContent = .{ .sort = lvl };
        return self.addTerm(t, content);
    }

    fn mkLambda(self: *Self, binderNameTk: Token, bType: ?Term, body: Term) Term {
        const binderName = self.identToName(binderNameTk.token(self.lx));
        const content: TermContent = .{ .lambda = .{ .binderName = binderName, .binderType = bType, .body = body } };
        return self.addTerm(binderNameTk, content);
    }

    fn mkPi(self: *Self, t: Token, binderName: Name, bType: ?Term, body: Term) Term {
        const content: TermContent = .{ .pi = .{ .binderName = binderName, .binderType = bType, .body = body } };
        return self.addTerm(t, content);
    }

    fn mkApp(self: *Self, t: Token, fun: Term, arg: Term) Term {
        const content: TermContent = .{ .app = .{ .fun = fun, .arg = arg } };
        return self.addTerm(t, content);
    }

    /// `level -> levelAtom ("+" NUMLIT)`
    fn level(self: *Self) ParserError!Level {
        const lvl = try self.levelAtom();
        if (self.lx.lookahead(0).kind == .plus) {
            _ = self.lx.next();
            const offset_t = try self.expect(.numlit);
            const offset = offset_t.numlitValue(self.lx, u32) catch return ParserError.SyntaxError;
            return self.lm.mkOffset(lvl, offset);
        } else return lvl;
    }

    /// Return Name id of an identifier.
    fn identToName(self: *Self, ident: []const u8) Name {
        const res = self.idents.getOrPut(ident) catch oom();
        if (res.found_existing) return res.value_ptr.*
        else {
            const new_name: Name = self.idents.count()-1; // both u32
            res.value_ptr.* = new_name;
            return new_name;
        }
    }

    /// levelAtom -> ident | "max" levelAtom levelAtom | "imax" levelAtom levelAtom | NUMLIT | "(" level ")"
    fn levelAtom(self: *Self) ParserError!Level {
        const t = try self.expect(.{ .ident, .max, .imax, .numlit, .lparen });
        switch (t.kind) {
            .ident => return self.lm.mkParam(self.identToName(t.token(self.lx))),
            .max => return self.lm.mkMax(try self.levelAtom(), try self.levelAtom()),
            .imax => return self.lm.mkIMax(try self.levelAtom(), try self.levelAtom()),
            .numlit => return self.lm.mkExplicit(t.numlitValue(self.lx, u32) catch return ParserError.SyntaxError),
            .lparen => {
                const res = try self.level();
                _ = try self.expect(.rparen);
                return res;
            },
            else => unreachable
        }
    }

    test "level" {
        const src = "max (u + 1) imax v (w + 5) + 7";
        const p = Parser.create(std.testing.allocator, src);
        defer p.destroy();
        const lvl = try p.level();
        const lvl_node = p.lm.getNode(lvl);
        try std.testing.expect(lvl_node.content.kind() == .max);
        try std.testing.expect(lvl_node.offset == 7);
        try std.testing.expect(p.lm.getNode(lvl_node.content.max.lhs).offset == 1);
    }

};
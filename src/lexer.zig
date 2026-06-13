const std = @import("std");
const oom = @import("common.zig").oom;
const Buffer = @import("common.zig").Buffer;

/// TODO: handle properly
pub fn utf8error() noreturn {
    @panic("malformed utf-8 detected");
}

pub const TokenKind = enum {
    eof,
    invalid,
    ident, // identifier
    numlit, // numeric literal

    // Atoms:

    def,
    axiom,
    check,
    universe,
    max,
    imax,
    sort,
    prop,
    lambda,
    import,

    lparen, // (
    rparen, // ) 
    colon, // :
    plus, // +

    coloneq, // :=
    to, // → or -> 
    mapsto, // ↦ or =>
    forall, // forall or ∀ or Π
    
};

// TODO: add builtin arithmetic operators +, -, *, ^, \cdot, =, <, <=, >, >=
// add more commands, add inductive type keywords
const builtinAtoms = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "def", .def },
    .{ "axiom", .axiom },
    .{ "#check", .check },
    .{ "universe", .universe },
    .{ "max", .max },
    .{ "imax", .imax },
    .{ "import", .import },
    .{ "Sort", .sort },
    .{ "Prop", .prop },
    .{ "fun", .lambda },
    .{ "λ", .lambda },
    .{ "forall", .forall },
    .{ "∀", .forall },
    .{ "Π", .forall },
    .{ "↦", .mapsto },
    .{ "→", .to },
});

fn isIdentAscii(c: u8) bool {
    // Non-ascii characters are caught by special handler
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isNumLit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentCont(c: u8) bool {
    return isIdentAscii(c) or isNumLit(c) or c == '\'' or c >= 0x80;
}

fn isWhitespace(c: u8) bool {
    // Actual Lean rejects '\t' but we allow it
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// A token is a slice of source code that represents one lexical unit.
/// Tokens come with a leading trivia - whitespace consisting of comments, spaces, newlines.
pub const Token = struct {
    kind: TokenKind,
    has_newline: bool, // whether leading trivia includes a newline
    source_offset: u32, // start of this Token's lexeme in original source
    len: u32, // total lexeme length
    offset: u32, // start of the actual Token (= length of leading trivia)

    /// A token is an atom if it is not an identifier, eof, literal or invalid.
    pub fn isAtom(t: Token) bool {
        return !t.isIdent() and !t.isInvalid() and !t.isEOF() and !t.isLiteral();
    }
    pub fn isLiteral(t: Token) bool { return t.kind == .numlit; }
    pub fn isIdent(t: Token) bool { return t.kind == .ident; }
    pub fn isInvalid(t: Token) bool { return t.kind == .invalid; }
    pub fn isEOF(t: Token) bool { return t.kind == .eof; }

    /// Return a token's main content. Assume that token is well-formed.
    pub fn token(t: Token, l: *Lexer) []const u8 {
        return l.src[t.source_offset+t.offset..t.source_offset+t.len];
    }

    /// Return a token's leading trivia.
    pub fn leading(t: Token, l: *Lexer) []const u8 {
        return l.src[t.source_offset..t.source_offset+t.offset];
    }

    /// Return complete lexeme of a token, including leading whitespace.
    pub fn lexeme(t: Token, l: *Lexer) []const u8 {
        return l.src[t.source_offset..t.source_offset+t.len];
    }

    /// Return true if token has leading whitespace (whitespace is anything that is not part of main token content).
    pub fn leadingWs(t: Token) bool {
        return t.offset > 0;
    }

    /// Return true if token has at least one newline in it's leading whitespace.
    pub fn leadingNewline(t: Token) bool {
        return t.has_newline;
    }

    /// Return value of numlit (must be u64)
    pub fn numlitValue(t: Token, l: *Lexer, comptime uintType: type) !uintType {
        std.debug.assert(t.kind == .numlit);
        const s = t.token(l);
        return try std.fmt.parseUnsigned(uintType, s, 10);
    }
};

// pub const LexerState = enum {
//     init, 
//     trivia, // first we read trivia
//     skip_whitespace,
//     line_cmt,
//     multiline_cmt,
// };

/// Simple lexer for MicroLean's syntax. The goal is to support a subset of Lean's syntax.
/// It isn't a proper subset because of various edge cases for now, but for most practical purposes should be fine.
/// Note actual Lean is lexer-less to allow
/// for flexible syntax extensions within Lean itself.
pub const Lexer = struct {
    const Self = @This();

    src: []const u8, // Source code
    cur: usize = 0, // Points to next character in source to be read
    
    // state: LexerState = .init, // The lexer is a finite state machine
    cur_t: Token, // Used to keep state while reading token
    
    cur_t_i: usize = 0,
    buf: Buffer(Token),
    lines: Buffer(usize), // Store locations of new lines

    pub fn init(allocator: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .src = src, .cur_t = undefined,
            .buf = .init(allocator),
            .lines = .init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.buf.deinit();
        self.lines.deinit();
    }

    /// Read the token at given offset from current token index.
    pub fn lookahead(self: *Self, offset: usize) Token {
        self.ensureBuf(offset);
        return self.buf.get(self.cur_t_i + offset);
    }

    /// Return token at current position and advance token index.
    pub fn next(self: *Self) Token {
        self.ensureBuf(0);
        const t = self.buf.get(self.cur_t_i);
        self.cur_t_i += 1;
        return t;
    }

    /// Return line number of given position in source by binary search.
    pub fn lineNumber(self: *Self, pos: usize) usize {
        var lower_bd = 0;
        var upper_bd = self.lines.len();
        while (upper_bd > lower_bd + 1) {
            const mid = lower_bd + ((upper_bd - lower_bd) >> 1);
            const lpos = self.lines.get(mid);
            if (lpos < pos) lower_bd = mid
            else if (lpos > pos) upper_bd = mid
            else return mid + 1; // Newline character itself is counted as belonging to previovus line.
        }
        return upper_bd + 1;
    }

    test "lineNumber" {
        const src = 
            \\0123456
            \\8 --
            \\13
            \\
        ;
        var l = Lexer.init(std.testing.allocator, src);
        while (!l.next().isEOF()) {}
        try std.testing.expect(l.lines.len() == 3);
        try std.testing.expect(l.lineNumber(0) == 1);
        try std.testing.expect(l.lineNumber(8) == 2);
        try std.testing.expect(l.lineNumber(12) == 2);
        try std.testing.expect(l.lineNumber(13) == 3);
        try std.testing.expect(l.lineNumber(16) == 4);
    }

    // pub fn rewind(self: *Self, offset: usize) void {
    //     self.cur_t_i = @max(0, self.cur_t_i - offset);
    // }

    /// Ensure that token buffer is filled up to specified offset from current position.
    fn ensureBuf(self: *Self, offset: usize) void {
        const target = self.cur_t_i + offset;
        while (target >= self.buf.len()) {
            self.buf.append(self.nextCore());
        }
    }

    // Read next token.
    fn nextCore(self: *Self) Token {
        self.initToken();
        // if (self.isAtEnd()) return self.mkToken(.eof);

        self.whitespace(); // skip trivia
        if (self.isAtEnd()) return self.mkToken(.eof);

        const c = self.peek(0);

        switch (c) {
            '(' => { self.skip(); return self.mkToken(.lparen); },
            ')' => { self.skip(); return self.mkToken(.rparen); },
            '+' => { self.skip(); return self.mkToken(.plus); },
            ':' => return self.handleColon(),
            '-' => return self.handleDash(),
            '=' => return self.handleEq(),
            '#' => return self.handleCmd(),
            else => {}
        }

        if (c >= 0x80) {
            // Check if this is a non-ascii single character atom like `→`
            const full_c = self.peekFull();
            if (builtinAtoms.get(full_c)) |kind| {
                self.cur = @min(self.src.len, self.cur + full_c.len);
                return self.mkToken(kind);
            } else {
                // If not, for simplicity run identifier or keyword handler.
                // TODO: More careful with validation
                return self.identOrKeyword();
            }
        }

        if (isIdentAscii(c)) return self.identOrKeyword()
        else if (isNumLit(c)) return self.numLit()
        else {
            self.skip();
            return self.mkToken(.invalid);
        }
    }

    // Handle command starting on '#'
    fn handleCmd(self: *Self) Token {
        self.skip();
        while (isIdentAscii(self.peek(0))) self.skip();
        const token = self.src[self.cur_t.source_offset+self.cur_t.offset..self.cur];
        if (builtinAtoms.get(token)) |kind| {
            return self.mkToken(kind);
        } else {
            // @panic("expected valid command after '#'");
            return self.mkToken(.invalid);
        }
    }

    fn initToken(self: *Self) void {
        self.cur_t = .{ .has_newline = false,
            .kind = .invalid,
            .offset = 0,
            .source_offset = @intCast(self.cur),
            .len = 0 };
    }

    // Special handler for `:` or `:=`
    fn handleColon(self: *Self) Token {
        self.skip();
        if (self.peek(0) == '=') {
            self.skip();
            return self.mkToken(.coloneq);
        } else {
            return self.mkToken(.colon);
        }
    }

    // Special handler for `->`
    fn handleDash(self: *Self) Token {
        self.skip();
        if (self.peek(0) == '>') {
            self.skip();
            return self.mkToken(.to);
        } else {
            return self.mkToken(.invalid);
        }
    }

    // Special handler for `=>`
    fn handleEq(self: *Self) Token {
        self.skip();
        if (self.peek(0) == '>') {
            self.skip();
            return self.mkToken(.mapsto);
        } else {
            return self.mkToken(.invalid);
        }
    }

    fn identOrKeyword(self: *Self) Token {
        // TODO: Allow hierarchical identifiers using `.`
        // For now accept all non-ascii bytes as part of a utf-8 identifier here
        while (isIdentCont(self.peek(0))) self.skip();
        const token = self.src[self.cur_t.source_offset+self.cur_t.offset..self.cur];
        if (builtinAtoms.get(token)) |kind| {
            return self.mkToken(kind);
        } else {
            // TODO: validate identifier
            return self.mkToken(.ident);
        }
    }

    fn numLit(self: *Self) Token {
        while (isNumLit(self.peek(0))) self.skip();
        return self.mkToken(.numlit);
    }

    /// Finalize current token assuming that we just read its last byte.
    fn mkToken(self: *Self, kind: TokenKind) Token {
        self.cur_t.kind = kind;
        self.cur_t.len = @intCast(self.cur - self.cur_t.source_offset);
        return self.cur_t;
    }

    /// Skip ahead until non-whitespace detected
    /// TODO: Later store some indentation info. 
    /// Lean syntax also has some indentation awareness, we currently ignore that.
    fn whitespace(self: *Self) void {
        while (true) {
            while (isWhitespace(self.peek(0))) self.skip();
            const c = self.peek(0);            
            switch (c) {
                '-' => if (self.peek(1) == '-') self.singleLineComment() else break,
                '/' => if (self.peek(1) == '-') self.multilineComment() else break,
                else => break
            }
        }
        // update token data
        const ws_len = self.cur - self.cur_t.source_offset;
        self.cur_t.offset = @intCast(ws_len);
    }

    /// Skip multiline comment. TODO: handle nested comments
    fn multilineComment(self: *Self) void {
        self.skip(); self.skip();
        var c = self.advance();
        while (c != '-' or self.peek(0) != '/') {
            if (self.isAtEnd()) @panic("expected '-/', got eof");
            c = self.advance();
        }
        self.skip();
    }

    /// Skip single line comment.
    fn singleLineComment(self: *Self) void {
        self.skip(); self.skip();
        var c = self.advance();
        while (c != '\n') {
            if (self.isAtEnd()) return;
            c = self.advance();
        }
    }

    fn isAtEnd(self: *Self) bool {
        std.debug.assert(self.cur <= self.src.len);
        return self.cur == self.src.len;
    }

    // /// Return true if provided slice is found at current position. 
    // /// Maybe not needed
    // fn match(self: *Self, comptime c: []const u8) bool {
    //     if (self.cur + c.len > self.src.len) return false;
    //     if (c.len == 1) {
    //         return self.src[self.cur] == c[0];
    //     } else {
    //         return std.mem.eql(u8, self.src[self.cur..self.cur+c.len], c);
    //     }
    // }

    /// Peek a certain number of bytes ahead.
    fn peek(self: *Self, comptime offset: usize) u8 {
        if (self.cur+offset >= self.src.len) return 0xFF;
        return self.src[self.cur+offset];
    }

    /// Skip a byte.
    fn skip(self: *Self) void {
        _ = self.advance();
    }

    /// Advance only one byte.
    fn advance(self: *Self) u8 {
        if (self.cur >= self.src.len) return 0xFF;
        const c = self.src[self.cur];
        if (c == '\n') {
            self.cur_t.has_newline = true;
            self.lines.append(self.cur);
        }
        self.cur += 1;
        return c;
    }

    /// Read next utf-8 character without advancing pointer.
    fn peekFull(self: *Self) []const u8 {
        std.debug.assert(self.cur < self.src.len);
        const b: u8 = self.src[self.cur];
        std.debug.assert(b >= 0x80); // meant to be called only on non-ascii bytes
        const len = std.unicode.utf8ByteSequenceLength(b) catch return self.handleutf8error();
        std.debug.assert(self.cur + len <= self.src.len);
        const res = self.src[self.cur..self.cur+len];
        std.debug.assert(std.unicode.utf8ValidateSlice(res));
        return res;
    }

    /// Read next full utf-8 character as a slice of source and advance source pointer.
    fn advanceFull(self: *Self) []const u8 {
        const res = self.peekFull();
        self.cur += res.len;
        return res;
    }

    // fn skipFull(self: *Self) void {
    //     _ = self.advanceFull();
    // }

    fn handleutf8error(self: *Self) []const u8 {
        // Todo: return unknown character codepoint and advance to next start byte
        _ = self;
        utf8error();
    }

    test "advanceFull" {
        const src = "→∀=";
        var l = Lexer.init(std.testing.allocator, src);
        l.initToken();
        try std.testing.expect(std.mem.eql(u8, l.advanceFull(), "→"));
        try std.testing.expect(std.mem.eql(u8, l.advanceFull(), "∀"));
        try std.testing.expect(std.mem.eql(u8, l.advanceFull(), "="));
    }

};


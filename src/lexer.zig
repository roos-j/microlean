const std = @import("std");

/// TODO: handle properly
pub fn utf8error() noreturn {
    @panic("malformed utf-8 detected");
}

// command1
// command2

// Token categories:
// keyword -- built-in keyword such as import, def, etc.
// ident -- identifier
// punct -- punctuation symbol, not necessarily on: parentheses, colon, :=
// 
// comment

// Possible commands:
// `import` <filename>
// `def` <string> (<string> : term) : term := term

// TODO: add Nat literals?
pub const TokenKind = enum {
    eof,
    invalid,
    ident, // identifier
    lit, // numeric literal

    // Atoms:

    // keywords
    def,
    axiom,
    universe,
    sort,
    prop,
    lambda,
    pi,
    // punctuation
    to,
    mapsto,
    coloneq,
    l_paren,
    r_paren,
    colon,
};

const builtinAtoms = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "def", .def },
    .{ "axiom", .axiom },
    .{ "->", .to },
    .{ ":", .colon },
    .{ ":=", .coloneq }
});

fn isIdentStart(c: u21) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c >= 0x80;
}

fn isCmdStart(c: u21) bool {
    return c == '#';
}

fn isNumLit(c: u21) bool {
    return c >= '0' and c <= '9';
}

fn isIdentCont(c: u21) bool {
    return isIdentStart(c) or isNumLit(c) or c == '\'';
}

fn isWhitespace(c: u21) bool {
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

    pub fn isAtom(t: Token) bool {
        return !t.isIdent() and !t.isInvalid() and !t.isEOF() and !t.isLiteral();
    }
    pub fn isLiteral(t: Token) bool { return t.kind == .lit; }
    pub fn isIdent(t: Token) bool { return t.kind == .ident; }
    pub fn isInvalid(t: Token) bool { return t.kind == .invalid; }
    pub fn isEOF(t: Token) bool { return t.kind == .eof; }

    // Return a token's main content. Assume that token is well-formed.
    pub fn token(t: Token, l: *Lexer) []const u8 {
        return l.src[t.source_offset+t.offset..t.source_offset+t.len];
    }

    // Return a token's leading trivia.
    pub fn leading(t: Token, l: *Lexer) []const u8 {
        return l.src[t.source_offset..t.source_offset+t.offset];
    }

    // Return complete lexeme of a token.
    pub fn lexeme(t: Token, l: *Lexer) []const u8 {
        return l.src[t.source_offset..t.source_offset+t.len];
    }

    // Return true if token has leading whitespace (whitespace is anything that is not part of main token content).
    pub fn leadingWs(t: Token) bool {
        return t.offset > 0;
    }

    // Return true if token has a leading newline.
    pub fn leadingNewline(t: Token) bool {
        return t.has_newline;
    }
};

pub const LexerState = enum {
    init, 
    trivia, // first we read trivia
    skip_whitespace,
    line_cmt,
    multiline_cmt,
};

pub const Lexer = struct {
    const Self = @This();

    src: []const u8, // Source code
    cur: usize = 0, // Points to next character in source to be read
    
    state: LexerState = .init, // The lexer is a finite state machine
    cur_t: Token, // Used to keep state while reading token

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src, .cur_t = undefined };
    }

    pub fn deinit(self: *Self) void {
        _ = self;   
    }

    // Read next token.
    pub fn next(self: *Self) Token {
        if (self.isAtEnd()) return mkEmptyEOF();

        // Cases
        // Identifier syntax: [a-zA-Z]([\.]?[a-zA-Z0-9]+)*
        // Keyword syntax: [#]?identifier
        // Literal: [0-9]+
        // Punctuation: ( ) := :
        // Newline: \n
        // 
        self.cur_t = .{ .has_newline = false,
            .kind = .invalid,
            .offset = 0,
            .source_offset = self.cur,
            .len = 0 };
        
        self.whitespace(); // skip trivia

        // const c: u8 = self.advance();
        
        // switch (c) {
            
        // }

    }

    /// Skip ahead until non-whitespace detected
    fn whitespace(self: *Self) void {
        while (true) {
            while (isWhitespace(self.peek(0))) self.skip();
            const c = self.peek(0);            
            switch (c) {
                '-' => self.singleLineComment(),
                '/' => self.multilineComment(),
                else => break
            }
        }
    }

    /// Skip multiline comment. TODO: handle nested comments
    fn multilineComment(self: *Self) void {
        if (self.peek(1) != '-') return;
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
        if (self.peek(1) != '-') return;
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

    /// Return true if provided slice is found at current position. 
    /// Maybe not needed
    fn match(self: *Self, comptime c: []const u8) bool {
        if (self.cur + c.len >= self.src.len) return false;
        if (c.len == 1) {
            return self.src[self.cur] == c[0];
        } else {
            return std.mem.eql(u8, self.src[self.cur..self.cur+c.len], c);
        }
    }

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
        if (c == '\n') self.cur_t.has_newline = true;
        self.cur += 1;
        return c;
    }

    /// Read next utf-8 character without advancing pointer.
    fn peekFull(self: *Self) []const u8 {
        std.debug.assert(self.cur < self.src.len);
        const b: u8 = self.src[self.cur];
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

    fn handleutf8error(self: *Self) []const u8 {
        // Todo: return unknown character codepoint and advance to next start byte
        _ = self;
        @panic("malformed utf-8");
    }

    test "Lexer.advanceFull" {
        const src = "→∀=";
        var l = Lexer.init(src);
        try std.testing.expect(std.mem.eql(u8, l.advanceFull(), "→"));
        try std.testing.expect(std.mem.eql(u8, l.advanceFull(), "∀"));
        try std.testing.expect(std.mem.eql(u8, l.advanceFull(), "="));
    }

    fn mkEmptyEOF(self: *Self) Token {
        return .{ .kind = .eof, 
            .has_newline = false,
            .offset = 0,
            .len = 0,
            .source_offset = self.src.len };
    }

};


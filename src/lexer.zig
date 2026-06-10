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

const builtin_atoms = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "def", .def },
    .{ "axiom", .axiom },
    .{ "->", .to },
    .{ ":", .colon },
    .{ ":=", .coloneq }
});



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
        if (self.cur >= self.src.len) return mkEmptyEOF();

        // Identifier syntax: [a-zA-Z]([\.]?[a-zA-Z0-9]+)*
        // Keyword syntax: [#]?identifier
        // Literal: [0-9]+
        self.cur_t = .{ .has_newline = false,
            .kind = .invalid,
            .offset = 0,
            .source_offset = self.cur,
            .len = 0 };
        
        // Tbc
    }

    // /// Read next source code byte. Careful with UTF-8. May not need this at all
    // fn advance(self: *Self) u8 {
    //     std.debug.assert(self.cur < self.src.len);
    //     const res = self.src[self.cur];
    //     self.cur += 1;
    //     return res;
    // }

    /// Read next full UTF-8 character as a slice of source.
    fn advanceUTF8(self: *Self) ![]const u8 {
        std.debug.assert(self.cur < self.src.len);
        const b: u8 = self.src[self.cur];
        const len = std.unicode.utf8ByteSequenceLength(b) catch utf8error();
        std.debug.assert(self.cur + len <= self.src.len);
        const res = self.src[self.cur..self.cur+len];
        std.debug.assert(std.unicode.utf8ValidateSlice(res));
        self.cur += len;
        return res;
    }

    fn mkEmptyEOF(self: *Self) Token {
        return .{ .kind = .eof, 
            .has_newline = false,
            .offset = 0,
            .len = 0,
            .source_offset = self.src.len };
    }

};


const std = @import("std");
const Lexer = @import("src/lexer.zig").Lexer;


test "Lexer" {

    const src = 
        \\axiom Nat : Type
        \\axiom zero : Nat
        \\axiom succ : Nat -> Nat
        \\def one := succ zero
    ;

    var l = Lexer.init(std.testing.allocator, src);
    defer l.deinit();

    var t = l.next();
    try std.testing.expect(t.kind == .axiom);
    try std.testing.expect(std.mem.eql(u8, t.lexeme(&l), "axiom"));
    try std.testing.expect(std.mem.eql(u8, t.leading(&l), ""));
    try std.testing.expect(!t.has_newline);

    t = l.next();
    try std.testing.expect(t.kind == .ident);
    try std.testing.expect(std.mem.eql(u8, t.token(&l), "Nat"));
    try std.testing.expect(std.mem.eql(u8, t.lexeme(&l), " Nat"));

    t = l.next();
    try std.testing.expect(t.kind == .colon);
    try std.testing.expect(std.mem.eql(u8, t.lexeme(&l), " :"));

    t = l.next();
    t = l.next();
    try std.testing.expect(t.kind == .axiom);
    try std.testing.expect(t.has_newline);
}
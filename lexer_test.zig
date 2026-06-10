const std = @import("std");
const Lexer = @import("src/lexer.zig").Lexer;

test "Lexer" {

    const src = 
        \\axiom Nat : Type
        \\axiom zero : Nat
        \\axiom succ : Nat -> Nat
        \\def one := succ zero
    ;

    var l = Lexer.init(src);
    defer l.deinit();

    
}
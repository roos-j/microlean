const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Expr = @import("expr.zig").Expr;
const Buffer = @import("common.zig").Buffer;

/// Parser for MicroLean
/// We implement a simple recursive descent parser.
/// Almost LL(1) grammar (except for arbitrary identifier look ahead):
///
/// file -> command*
/// command -> declaration | cmd
/// cmd -> "#check" term
/// declaration -> "axiom" IDENT ':' term | "def" IDENT (":" term)? ":=" term
///
/// term -> lambda | funType | sort
/// 
/// sort -> "Sort" level | "Prop"
/// level -> ident | "max" level level | "imax" level level | numlit | level "+" numlit | "(" level ")"
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
};

pub const TermNode = union(TermKind) {
    lambda: TermBinder,
    pi: TermBinder,
    app: TermApp,
    sort: TermLevel,
    ident: Slice,
    numlit: u64, // Actual Lean has no size restriction here
};

pub const TermApp = struct {
    // TODO
};

pub const TermBinder = struct {
    // TODO
};

pub const TermLevel = struct {
    // TODO
};

pub const Parser = struct {
    const Self = @This();

    l: *Lexer,
    terms: Buffer(TermNode)

    // fn level(self: *Self) Term {
        
    // }    

};
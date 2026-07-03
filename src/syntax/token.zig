//! Token definitions shared between scanner and parser.
//! Simple, flat token type — no logic.

pub const TokenType = enum(u8) {
    // ---- single-character ----
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    left_bracket,
    right_bracket,
    comma,
    colon,
    dot,
    at,
    minus,
    plus,
    semicolon,
    slash,
    star,
    question_mark, // ? (has-attr and default params)
    dollar_curly, // ${

    // ---- compound ----
    bang,
    bang_equal,
    equal,
    equal_equal,
    greater,
    greater_equal,
    less,
    less_equal,
    amp_amp, // &&
    pipe_pipe, // ||
    double_plus, // ++
    double_slash, // // (update operator)
    ellipsis, // ...
    arrow, // ->

    // ---- literals ----
    identifier,
    string,
    integer,
    float_val,
    path,
    search_path,

    // ---- keywords ----
    kw_if,
    kw_then,
    kw_else,
    kw_assert,
    kw_with,
    kw_let,
    kw_in,
    kw_rec,
    kw_inherit,
    kw_or,
    kw_true,
    kw_false,
    kw_null,

    // ---- special ----
    error_token,
    eof,
};

pub const Token = struct {
    type: TokenType,
    /// Offset and length into the source.
    offset: u32,
    len: u32,
    /// Line number (1-based).
    line: u32,
};

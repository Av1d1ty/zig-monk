const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("token.zig").Token;

const Precedence = enum {
    lowest,
    equals,
    less_greater,
    sum,
    product,
    prefix,
    call,

    pub fn of(token: Token) @This() {
        return switch (token) {
            .eq, .not_eq => .equals,
            .lt, .gt => .less_greater,
            .plus, .minus => .sum,
            .slash, .asterisk => .product,
            else => .lowest,
        };
    }
};

const Parser = struct {
    lexer: *Lexer,
    errors: std.ArrayList(anyerror),

    curr_token: Token = Token.illegal,
    peek_token: Token = Token.illegal,

    expression_pointers: std.ArrayList(*ast.Expression),

    pub fn init(lexer: *Lexer) @This() {
        var p = Parser{
            .lexer = lexer,
            .errors = std.ArrayList(anyerror).init(std.testing.allocator),
            .expression_pointers = std.ArrayList(*ast.Expression).init(std.testing.allocator),
        };
        p.next_token();
        p.next_token();
        return p;
    }

    pub fn deinit(self: *@This()) void {
        self.errors.deinit();
        self.expression_pointers.deinit();
    }

    pub fn parse_program(self: *@This()) !ast.Program {
        var program = ast.Program{
            .statements = std.ArrayList(ast.Statement).init(std.testing.allocator),
            .expression_pointers = std.ArrayList(*ast.Expression).init(std.testing.allocator),
        };
        while (self.curr_token != Token.eof) : (self.next_token()) {
            const statement = self.parse_statement() catch |e| {
                try self.errors.append(e);
                continue;
            };
            try program.statements.append(statement);
        }
        program.expression_pointers = try self.expression_pointers.clone();
        return program;
    }

    fn next_token(self: *@This()) void {
        self.curr_token = self.peek_token;
        self.peek_token = self.lexer.next_token();
    }

    fn parse_statement(self: *@This()) !ast.Statement {
        return switch (self.curr_token) {
            .let => .{ .let = try self.parse_let_statement() },
            .return_token => .{ .ret = self.parse_return_statement() },
            else => .{ .exp = try self.parse_expression_statement() },
        };
    }

    fn parse_let_statement(self: *@This()) !ast.LetStatement {
        const token = self.curr_token;
        switch (self.peek_token) {
            .ident => self.next_token(),
            else => return error.NextTokenNotIdent,
        }
        const ident = ast.Identifier{ .token = self.curr_token };
        while (self.curr_token != Token.semicolon) : (self.next_token()) {}
        return ast.LetStatement{ .token = token, .name = ident };
    }

    fn parse_return_statement(self: *@This()) ast.ReturnStatement {
        const token = self.curr_token;
        while (self.curr_token != Token.semicolon) : (self.next_token()) {}
        return ast.ReturnStatement{ .token = token, .value = null };
    }

    fn parse_expression_statement(self: *@This()) !ast.ExpressionStatement {
        const token = self.curr_token;
        const expression = try self.parse_expression();
        if (self.peek_token == Token.semicolon) self.next_token();
        return ast.ExpressionStatement{ .token = token, .expression = expression };
    }

    fn parse_expression(self: *@This()) !ast.Expression {
        var left_exp = try self.exec_prefix_fn(self.curr_token);
        while (true) {
            switch (self.peek_token) {
                .semicolon => { // NOTE: can I use `break` here?
                    return left_exp;
                },
                else => { // consider precedence
                    self.next_token();
                    left_exp = try self.exec_infix_fn(left_exp);
                },
            }
        }
        return left_exp;
    }

    // TODO: get rid of `anyerror`
    // NOTE: Do I really need to pass the token?
    fn exec_prefix_fn(self: *@This(), token: Token) anyerror!ast.Expression {
        // std.debug.print("\ntoken: {any}", .{token});
        return switch (token) {
            .ident => ast.Expression{ .ident = ast.Identifier{ .token = self.curr_token } },
            .int => ast.Expression{ .int = ast.IntegerLiteral{
                .token = self.curr_token,
                .value = try std.fmt.parseInt(i64, self.curr_token.get_value().?, 10),
            } },
            .minus, .bang => blk: {
                const tok = self.curr_token;
                self.next_token();
                const exp = try std.testing.allocator.create(ast.Expression);
                exp.* = try self.parse_expression();
                try self.expression_pointers.append(exp);
                break :blk ast.Expression{ .pref = ast.Prefix{ .token = tok, .right = exp } };
            },
            else => unreachable,
        };
    }

    // TODO: get rid of `anyerror`
    fn exec_infix_fn(self: *@This(), left: ast.Expression) anyerror!ast.Expression {
        const token = self.curr_token;
        var var_left = left;
        // const operator = self.curr_token.
        self.next_token();

        const exp = try std.testing.allocator.create(ast.Expression);
        exp.* = try self.parse_expression(); // precedence?
        try self.expression_pointers.append(exp);

        return ast.Expression{
            .inf = ast.Infix{
                .token = token,
                // .operator = null,
                .left = &var_left,
                .right = exp,
            },
        };
    }
};

const expect = std.testing.expect;
test "let_statements" {
    const input =
        \\ let x = 5;
        \\ let y = 10;
        \\ let foobar = 838383;
    ;
    var lexer = Lexer.init(input);
    var parser = Parser.init(&lexer);
    var program = try parser.parse_program();

    defer parser.deinit();
    defer program.deinit();

    // if (parser.errors.items.len > 0) {
    //     for (parser.errors.items) |val| {
    //         std.log.err("{s}\n", .{@errorName(val)});
    //     }
    //     unreachable;
    // }

    try expect(program.statements.items.len == 3);
    try expect(parser.errors.items.len == 0);

    const expected_identifiers = [_][]const u8{ "x", "y", "foobar" };
    for (program.statements.items, expected_identifiers) |statement, ident| {
        switch (statement) {
            .let => |val| {
                try expect(std.mem.eql(u8, val.name.token.get_value().?, ident));
            },
            else => unreachable,
        }
    }
}

test "return_statements" {
    const input =
        \\ return 5;
        \\ return 10;
        \\ return 4242;
    ;
    var lexer = Lexer.init(input);
    var parser = Parser.init(&lexer);
    var program = try parser.parse_program();

    defer parser.deinit();
    defer program.deinit();

    try expect(program.statements.items.len == 3);
    try expect(parser.errors.items.len == 0);

    // const expected_values = [_][]const u8{ "5", "6", "4242" };
    for (program.statements.items) |statement| {
        try expect(statement.ret.token == Token.return_token);
    }
}

test "expressions" {
    const input =
        \\ foobar;
        \\ 5;
    ;

    var lexer = Lexer.init(input);
    var parser = Parser.init(&lexer);
    var program = try parser.parse_program();

    defer parser.deinit();
    defer program.deinit();

    try expect(program.statements.items.len == 2);
    try expect(parser.errors.items.len == 0);

    const expected_identifiers = [_][]const u8{ "foobar", "5" };
    // NOTE: integer literal values are not validated for now
    for (program.statements.items, expected_identifiers) |statement, ident| {
        switch (statement) {
            .exp => |val| {
                try expect(std.mem.eql(u8, val.token.get_value().?, ident));
            },
            else => unreachable,
        }
    }
}

test "prefix" {
    const PrefixTestCase = struct {
        input: []const u8,
        operator: u8,
        integer: i64,
    };
    const test_cases = [_]PrefixTestCase{
        .{ .input = "!5;", .operator = '!', .integer = 5 },
        .{ .input = "-15;", .operator = '-', .integer = 15 },
    };

    for (test_cases) |case| {
        var lexer = Lexer.init(case.input);
        var parser = Parser.init(&lexer);
        var program = try parser.parse_program();

        defer parser.deinit();
        defer program.deinit();

        try expect(program.statements.items.len == 1);
        try expect(parser.errors.items.len == 0);

        for (program.statements.items) |statement| {
            switch (statement.exp.expression) {
                .pref => |pref| {
                    try expect(pref.right.int.value == case.integer);
                    switch (pref.token) {
                        .bang => try expect(case.operator == '!'),
                        .minus => try expect(case.operator == '-'),
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
        }
    }
}

test "infix" {
    const InfixTestCase = struct {
        input: []const u8,
        left_value: i64,
        operator: []const u8,
        right_value: i64,
    };
    const test_cases = [_]InfixTestCase{
        .{ .input = "5 + 5;", .left_value = 5, .operator = "+", .right_value = 5 },
        .{ .input = "5 - 5;", .left_value = 5, .operator = "-", .right_value = 5 },
        .{ .input = "5 * 5;", .left_value = 5, .operator = "*", .right_value = 5 },
        .{ .input = "5 / 5;", .left_value = 5, .operator = "/", .right_value = 5 },
        .{ .input = "5 > 5;", .left_value = 5, .operator = ">", .right_value = 5 },
        .{ .input = "5 < 5;", .left_value = 5, .operator = "<", .right_value = 5 },
        .{ .input = "5 == 5;", .left_value = 5, .operator = "==", .right_value = 5 },
        .{ .input = "5 != 5;", .left_value = 5, .operator = "!=", .right_value = 5 },
    };

    for (test_cases) |case| {
        var lexer = Lexer.init(case.input);
        var parser = Parser.init(&lexer);
        var program = try parser.parse_program();

        defer parser.deinit();
        defer program.deinit();

        try expect(program.statements.items.len == 1);
        try expect(parser.errors.items.len == 0);

        for (program.statements.items) |statement| {
            switch (statement.exp.expression) {
                .inf => |inf| {
                    std.debug.print("\ninf: {any}", .{inf});
                    std.debug.print("\nleft: {any}", .{inf.left});
                    std.debug.print("\nright: {any}", .{inf.right});
                    try expect(inf.left.int.value == case.left_value);
                    try expect(inf.right.int.value == case.right_value);
                    switch (inf.token) {
                        .plus => try expect(std.mem.eql(u8, case.operator, "+")),
                        .minus => try expect(std.mem.eql(u8, case.operator, "-")),
                        .asterisk => try expect(std.mem.eql(u8, case.operator, "*")),
                        .slash => try expect(std.mem.eql(u8, case.operator, "/")),
                        .gt => try expect(std.mem.eql(u8, case.operator, ">")),
                        .lt => try expect(std.mem.eql(u8, case.operator, "<")),
                        .eq => try expect(std.mem.eql(u8, case.operator, "==")),
                        .not_eq => try expect(std.mem.eql(u8, case.operator, "!=")),
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
        }
    }
}

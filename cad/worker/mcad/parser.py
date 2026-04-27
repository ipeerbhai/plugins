"""Recursive-descent parser for the MCAD DSL (V1 subset).

Consumes a token list produced by ``mcad.lexer.tokenize`` and builds an AST
defined in ``mcad.ast_nodes``.

Design decisions
----------------
* ``+`` / ``-`` are always ``BinOp`` — the translator resolves arithmetic vs
  CSG based on operand types.
* ``at (x, y)`` attaches to the *preceding* constructor call, producing an
  ``AtClause`` node that wraps the ``FuncCall``.
* ``center at point(x, y)`` is the explicit placement form. It lowers to the
  same ``AtClause`` representation as ``at (x, y)`` with ``anchor="center"``.
* ``fillet beam, 2, r=4`` is a ``Command`` with positional args ``[beam, 2]``
  and kwargs ``{r: 4}``.  The parser distinguishes commands (bare arg list)
  from constructors (parenthesised arg list).
* ``extrude(profile, length)`` is parsed as a ``FuncCall`` first and then
  lowered to an ``Extrude`` AST node for clarity.
"""

from __future__ import annotations

from typing import Any

from .ast_nodes import (
    Assignment,
    AtClause,
    BinOp,
    Bool,
    Command,
    Export,
    Extrude,
    ForLoop,
    FuncCall,
    Identifier,
    If,
    Index,
    Loft,
    LoftSection,
    MethodCall,
    ModuleDef,
    Number,
    Parameter,
    Program,
    Return,
    SketchBlock,
    String,
    Tuple,
    UnaryOp,
    While,
)
from .lexer import LexError, TT, Token


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Command keywords that take a bare (non-parenthesised) argument list
_COMMAND_KEYWORDS: set[TT] = {
    TT.KW_FILLET,
    TT.KW_CHAMFER,
    TT.KW_SHELL,
    TT.KW_SPLIT,
    TT.KW_CUT,
    TT.KW_ADD,
    TT.KW_JOIN,
    TT.KW_CAP,
    TT.KW_PATTERN,
}


class ParseError(Exception):
    def __init__(self, message: str, token: Token | None = None):
        self.token = token
        loc = f" at line {token.line}, col {token.col}" if token else ""
        super().__init__(f"{message}{loc}")


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

class Parser:
    """Recursive-descent parser for MCAD source."""

    def __init__(self, tokens: list[Token]):
        self.tokens = tokens
        self.pos = 0
        # Depth counter: >0 while we're parsing inside a module body.
        # `return` is only valid when this is non-zero.
        self._in_module_depth = 0

    # -- Utilities ----------------------------------------------------------

    def _peek(self) -> Token:
        return self.tokens[self.pos]

    def _at(self, *types: TT) -> bool:
        return self._peek().type in types

    def _advance(self) -> Token:
        tok = self.tokens[self.pos]
        self.pos += 1
        return tok

    def _expect(self, tt: TT, context: str = "") -> Token:
        tok = self._peek()
        if tok.type != tt:
            ctx = f" ({context})" if context else ""
            raise ParseError(f"Expected {tt.name} but got {tok.type.name}{ctx}", tok)
        return self._advance()

    def _skip_newlines(self) -> None:
        while self._at(TT.NEWLINE):
            self._advance()

    # -- Top-level ----------------------------------------------------------

    def parse(self) -> Program:
        stmts: list[Any] = []
        self._skip_newlines()
        while not self._at(TT.EOF):
            stmts.append(self._statement())
            self._skip_newlines()
        return Program(stmts)

    # -- Statements ---------------------------------------------------------

    def _statement(self) -> Any:
        tok = self._peek()

        # sketch:
        if tok.type == TT.KW_SKETCH:
            return self._sketch_block()

        # for <var> in <expr>:
        if tok.type == TT.KW_FOR:
            return self._for_loop()

        # if <expr>: ... [else: ...]
        if tok.type == TT.KW_IF:
            return self._if_statement()

        # while <expr>: ...
        if tok.type == TT.KW_WHILE:
            return self._while_statement()

        # module <name>(<params>): ...
        if tok.type == TT.KW_MODULE:
            return self._module_def()

        # return <expr> — only legal inside a module body.
        if tok.type == TT.KW_RETURN:
            return self._return_statement()

        # export <name> "<path>"
        if tok.type == TT.KW_EXPORT:
            return self._export_statement()

        # Orphan else: — no matching if.
        if tok.type == TT.KW_ELSE:
            raise ParseError("'else:' without matching 'if:'", tok)

        # Command keywords (fillet, chamfer, export, ...)
        if tok.type in _COMMAND_KEYWORDS:
            return self._command_stmt()

        # Assignment: IDENT = ...
        # We need lookahead to distinguish assignment from a bare expression.
        if tok.type == TT.IDENT:
            return self._assignment_or_expr_stmt()

        # extrude as function call: extrude(...)
        if tok.type == TT.KW_EXTRUDE:
            return self._assignment_or_expr_stmt()

        raise ParseError(f"Unexpected token {tok.type.name}", tok)

    def _assignment_or_expr_stmt(self) -> Any:
        """Parse an assignment (``name = expr``) or a bare expression statement."""
        tok = self._peek()

        # Check for assignment: IDENT EQ
        if tok.type == TT.IDENT and self.pos + 1 < len(self.tokens):
            next_tok = self.tokens[self.pos + 1]
            if next_tok.type == TT.EQ:
                return self._assignment()

        # Otherwise it's an expression statement (rare in V1 but possible)
        expr = self._expression()
        self._expect(TT.NEWLINE, "end of expression statement")
        return expr

    def _assignment(self) -> Assignment:
        name_tok = self._expect(TT.IDENT, "assignment target")
        self._expect(TT.EQ, "assignment")
        if self._at(TT.KW_LOFT):
            value = self._loft_block()
            return Assignment(name_tok.value, value)
        value = self._expression()

        # Check for at clause
        if self._at(TT.KW_AT):
            value = self._at_clause(value)

        self._expect(TT.NEWLINE, "end of assignment")
        return Assignment(name_tok.value, value)

    def _loft_block(self) -> Loft:
        """Parse ``loft:`` followed by indented section lines."""
        self._expect(TT.KW_LOFT, "loft block")
        self._expect(TT.COLON, "loft block")
        self._expect(TT.NEWLINE, "loft block")
        self._expect(TT.INDENT, "loft block body")

        sections: list[LoftSection] = []
        self._skip_newlines()
        while not self._at(TT.DEDENT):
            sections.append(self._loft_section())
            self._skip_newlines()

        self._expect(TT.DEDENT, "end of loft block")
        if len(sections) < 2:
            raise ParseError("loft requires at least 2 section lines")
        return Loft(sections=sections)

    def _loft_section(self) -> LoftSection:
        """Parse one section line: ``z=40: oval(60, 35)``."""
        axis_tok = self._expect(TT.IDENT, "loft section axis")
        self._expect(TT.EQ, "loft section position")
        position = self._expression()
        self._expect(TT.COLON, "loft section")
        profile = self._expression()
        self._expect(TT.NEWLINE, "end of loft section")
        return LoftSection(axis=str(axis_tok.value), position=position, profile=profile)

    # -- Sketch block -------------------------------------------------------

    def _sketch_block(self) -> SketchBlock:
        self._expect(TT.KW_SKETCH, "sketch block")
        self._expect(TT.COLON, "sketch block")
        self._expect(TT.NEWLINE, "sketch block")
        self._expect(TT.INDENT, "sketch block body")

        stmts: list[Any] = []
        self._skip_newlines()
        while not self._at(TT.DEDENT):
            stmts.append(self._statement())
            self._skip_newlines()

        self._expect(TT.DEDENT, "end of sketch block")
        return SketchBlock(stmts)

    # -- For loop -----------------------------------------------------------

    def _for_loop(self) -> ForLoop:
        self._expect(TT.KW_FOR, "for loop")
        var_tok = self._expect(TT.IDENT, "for-loop variable name")
        self._expect(TT.KW_IN, "for loop")
        iterable = self._expression()
        self._expect(TT.COLON, "for loop")
        self._expect(TT.NEWLINE, "for loop")
        self._expect(TT.INDENT, "for-loop body")

        body: list[Any] = []
        self._skip_newlines()
        while not self._at(TT.DEDENT):
            body.append(self._statement())
            self._skip_newlines()

        self._expect(TT.DEDENT, "end of for-loop body")
        if not body:
            raise ParseError("for-loop body must contain at least one statement", var_tok)
        return ForLoop(var_tok.value, iterable, body)

    # -- If / While ---------------------------------------------------------

    def _parse_indented_block(self, context: str) -> list[Any]:
        """Parse ``COLON NEWLINE INDENT <stmts> DEDENT`` and return the stmt list.

        The leading ``if``/``while``/``else`` keyword must already be consumed.
        """
        colon_tok = self._peek()
        self._expect(TT.COLON, context)
        self._expect(TT.NEWLINE, context)
        self._expect(TT.INDENT, f"{context} body")

        body: list[Any] = []
        self._skip_newlines()
        while not self._at(TT.DEDENT):
            body.append(self._statement())
            self._skip_newlines()

        self._expect(TT.DEDENT, f"end of {context} body")
        if not body:
            raise ParseError(f"{context} body must contain at least one statement", colon_tok)
        return body

    def _if_statement(self) -> If:
        if_tok = self._expect(TT.KW_IF, "if statement")
        condition = self._expression()
        then_body = self._parse_indented_block("if")

        else_body: list[Any] = []
        # After the if-body's DEDENT, we may be sitting on NEWLINEs before the
        # `else:` keyword.  Peek past them without consuming so we don't eat
        # top-level blank lines unnecessarily.
        save_pos = self.pos
        self._skip_newlines()
        if self._at(TT.KW_ELSE):
            self._advance()  # consume 'else'
            else_body = self._parse_indented_block("else")
        else:
            # Not an else — rewind so the outer loop handles the NEWLINEs.
            self.pos = save_pos

        return If(condition=condition, then_body=then_body, else_body=else_body)

    def _while_statement(self) -> While:
        self._expect(TT.KW_WHILE, "while statement")
        condition = self._expression()
        body = self._parse_indented_block("while")
        return While(condition=condition, body=body)

    # -- Module definition / return ----------------------------------------

    def _module_def(self) -> ModuleDef:
        """Parse ``module <name>(<params>):`` + indented body."""
        self._expect(TT.KW_MODULE, "module definition")
        name_tok = self._expect(TT.IDENT, "module name")
        self._expect(TT.LPAREN, "module parameter list")

        params: list[Parameter] = []
        seen_default = False
        if not self._at(TT.RPAREN):
            params.append(self._parse_parameter())
            if params[-1].default is not None:
                seen_default = True
            while self._at(TT.COMMA):
                self._advance()
                if self._at(TT.RPAREN):
                    break
                param = self._parse_parameter()
                if param.default is None and seen_default:
                    raise ParseError(
                        "required parameter cannot follow a defaulted parameter",
                        self._peek(),
                    )
                if param.default is not None:
                    seen_default = True
                params.append(param)
        self._expect(TT.RPAREN, "closing ')' for module parameters")

        # Parse the body inside a depth context so `return` is valid.
        self._in_module_depth += 1
        try:
            body = self._parse_indented_block(f"module {name_tok.value}")
        finally:
            self._in_module_depth -= 1

        return ModuleDef(name=name_tok.value, params=params, body=body)

    def _parse_parameter(self) -> Parameter:
        """Parse a single parameter: ``name`` or ``name = <expression>``."""
        name_tok = self._expect(TT.IDENT, "parameter name")
        default = None
        if self._at(TT.EQ):
            self._advance()  # consume '='
            default = self._expression()
        return Parameter(name=name_tok.value, default=default)

    def _return_statement(self) -> Return:
        """Parse ``return <expression>`` NEWLINE."""
        ret_tok = self._expect(TT.KW_RETURN, "return statement")
        if self._in_module_depth == 0:
            raise ParseError("'return' outside of module body", ret_tok)
        if self._at(TT.NEWLINE, TT.EOF):
            raise ParseError("'return' requires an expression", ret_tok)
        value = self._expression()
        self._expect(TT.NEWLINE, "end of return statement")
        return Return(value=value)

    # -- Command statement --------------------------------------------------

    def _export_statement(self) -> Export:
        """Parse ``export <name> "<path>"`` NEWLINE.

        Positional form: no comma between target and path. Path is a string
        literal; format is inferred from its extension by the translator.
        """
        kw_tok = self._expect(TT.KW_EXPORT, "export statement")
        if not self._at(TT.IDENT):
            raise ParseError(
                "export requires a shape name (e.g. `export beam \"beam.stl\"`)",
                self._peek(),
            )
        name_tok = self._advance()
        if not self._at(TT.STRING):
            raise ParseError(
                "export requires a quoted file path (e.g. `export beam \"beam.stl\"`)",
                self._peek(),
            )
        path_tok = self._advance()
        self._expect(TT.NEWLINE, "end of export statement")
        return Export(name=name_tok.value, path=path_tok.value)

    def _command_stmt(self) -> Command:
        """Parse ``fillet beam, 2, r=4``."""
        cmd_tok = self._advance()
        cmd_name = cmd_tok.value  # e.g. "fillet"

        args: list[Any] = []
        kwargs: dict[str, Any] = {}

        # Parse bare argument list (no parens)
        if not self._at(TT.NEWLINE, TT.EOF):
            self._parse_bare_args(args, kwargs)

        self._expect(TT.NEWLINE, f"end of {cmd_name} command")
        return Command(cmd_name, args, kwargs)

    def _parse_bare_args(self, args: list, kwargs: dict) -> None:
        """Parse a comma-separated bare argument list (no parens)."""
        self._parse_one_arg(args, kwargs)
        while self._at(TT.COMMA):
            self._advance()  # consume comma
            self._parse_one_arg(args, kwargs)

    def _parse_one_arg(self, args: list, kwargs: dict) -> None:
        """Parse a single argument — either ``key=expr`` (kwarg) or ``expr``."""
        # Check for kwarg: identifier-like token followed by '='.
        if self._at(TT.IDENT, TT.KW_CENTER) and self.pos + 1 < len(self.tokens):
            next_tok = self.tokens[self.pos + 1]
            if next_tok.type == TT.EQ:
                key_tok = self._advance()
                self._advance()  # consume '='
                value = self._expression()
                kwargs[key_tok.value] = value
                return

        args.append(self._expression())

    # -- Expressions --------------------------------------------------------

    def _expression(self) -> Any:
        return self._or_expr()

    # Precedence (lowest -> highest):
    #   ||  ->  &&  ->  !  ->  comparison  ->  +/-  ->  */ /  ->  unary -  ->  primary

    def _or_expr(self) -> Any:
        left = self._and_expr()
        while self._at(TT.PIPEPIPE):
            op_tok = self._advance()
            right = self._and_expr()
            left = BinOp(op_tok.value, left, right)
        return left

    def _and_expr(self) -> Any:
        left = self._not_expr()
        while self._at(TT.AMPAMP):
            op_tok = self._advance()
            right = self._not_expr()
            left = BinOp(op_tok.value, left, right)
        return left

    def _not_expr(self) -> Any:
        if self._at(TT.BANG):
            op_tok = self._advance()
            operand = self._not_expr()
            return UnaryOp(op_tok.value, operand)
        return self._comparison_expr()

    def _comparison_expr(self) -> Any:
        left = self._add_expr()
        # Non-associative-ish: we allow chaining left-associatively but
        # that's a fine V1 behaviour (``a < b < c`` parses as ``(a < b) < c``
        # which then errors at the translator).
        while self._at(TT.LT, TT.GT, TT.LTE, TT.GTE, TT.EQEQ, TT.BANGEQ):
            op_tok = self._advance()
            right = self._add_expr()
            left = BinOp(op_tok.value, left, right)
        return left

    def _add_expr(self) -> Any:
        left = self._mul_expr()
        while self._at(TT.PLUS, TT.MINUS):
            op_tok = self._advance()
            right = self._mul_expr()
            left = BinOp(op_tok.value, left, right)
        return left

    def _mul_expr(self) -> Any:
        left = self._unary_expr()
        while self._at(TT.STAR, TT.SLASH):
            op_tok = self._advance()
            right = self._unary_expr()
            left = BinOp(op_tok.value, left, right)
        return left

    def _unary_expr(self) -> Any:
        if self._at(TT.MINUS):
            op_tok = self._advance()
            operand = self._unary_expr()
            return UnaryOp(op_tok.value, operand)
        return self._postfix_expr()

    def _postfix_expr(self) -> Any:
        node = self._primary()
        while self._at(TT.DOT, TT.LBRACKET):
            if self._at(TT.DOT):
                self._advance()  # consume '.'
                method_tok = self._expect(TT.IDENT, "method name")
                self._expect(TT.LPAREN, "method call")
                m_args, m_kwargs = self._arg_list_inner()
                self._expect(TT.RPAREN, "method call")
                node = MethodCall(node, method_tok.value, m_args, m_kwargs)
            else:
                # LBRACKET after an already-parsed primary → postfix index
                self._advance()  # consume '['
                idx_expr = self._expression()
                self._expect(TT.RBRACKET, "closing ']' for index")
                node = Index(node, idx_expr)
        return node

    def _primary(self) -> Any:
        tok = self._peek()

        # Parenthesised expression or tuple
        if tok.type == TT.LPAREN:
            return self._paren_expr()

        if tok.type == TT.LBRACKET:
            return self._bracket_tuple()

        # Number literal
        if tok.type == TT.NUMBER:
            self._advance()
            return Number(tok.value)

        # Boolean literal
        if tok.type == TT.BOOL:
            self._advance()
            return Bool(bool(tok.value))

        # String literal
        if tok.type == TT.STRING:
            self._advance()
            return String(tok.value)

        # Function call or plain identifier
        if tok.type == TT.IDENT:
            return self._ident_or_func_call()

        # extrude keyword used as function call
        if tok.type == TT.KW_EXTRUDE:
            return self._extrude_func_call()

        raise ParseError(f"Expected expression, got {tok.type.name}", tok)

    def _paren_expr(self) -> Any:
        """Parse ``(expr)`` or a grouped sub-expression."""
        self._expect(TT.LPAREN, "grouped expression")
        expr = self._expression()

        # Check for tuple: (expr, expr, ...)
        if self._at(TT.COMMA):
            # This is not a tuple literal in V1 — it's just a parenthesised
            # expression.  But we still need to handle (x, y) as used in
            # at-clause positions.  For now, just parse the single expr.
            pass

        self._expect(TT.RPAREN, "closing parenthesis")
        return expr

    def _bracket_tuple(self) -> Tuple:
        """Parse ``[a, b, c]`` style vector literals."""
        self._expect(TT.LBRACKET, "vector literal")
        elements: list[Any] = []
        if not self._at(TT.RBRACKET):
            elements.append(self._expression())
            while self._at(TT.COMMA):
                self._advance()
                if self._at(TT.RBRACKET):
                    break
                elements.append(self._expression())
        self._expect(TT.RBRACKET, "closing ']'")
        return Tuple(elements)

    def _ident_or_func_call(self) -> Any:
        """Parse ``name`` or ``name(args)``."""
        name_tok = self._advance()

        # Check for function call
        if self._at(TT.LPAREN):
            self._advance()  # consume '('
            args, kwargs = self._arg_list_inner()
            self._expect(TT.RPAREN, f"closing ')' for {name_tok.value}()")

            node = FuncCall(name_tok.value, args, kwargs)

            # Check for placement clause immediately after
            if self._at(TT.KW_CENTER):
                node = self._center_at_clause(node)
            elif self._at(TT.KW_AT):
                node = self._at_clause(node)

            return node

        return Identifier(name_tok.value)

    def _extrude_func_call(self) -> Any:
        """Parse ``extrude(profile, length)`` as an Extrude node."""
        kw_tok = self._advance()  # consume 'extrude'

        if not self._at(TT.LPAREN):
            raise ParseError("Expected '(' after extrude", self._peek())

        self._advance()  # consume '('
        args, kwargs = self._arg_list_inner()
        self._expect(TT.RPAREN, "closing ')' for extrude()")

        if len(args) < 2:
            raise ParseError(
                f"extrude() requires 2 positional arguments (profile, length), got {len(args)}",
                kw_tok,
            )

        return Extrude(profile=args[0], length=args[1])

    def _at_clause(self, target: Any) -> AtClause:
        """Parse legacy ``at (x, y)`` and wrap *target*."""
        self._expect(TT.KW_AT, "at clause")

        # Position spec: (expr, expr) — parse as parenthesised comma list
        self._expect(TT.LPAREN, "at clause position")
        positions = [self._expression()]
        while self._at(TT.COMMA):
            self._advance()
            positions.append(self._expression())
        self._expect(TT.RPAREN, "at clause position")

        return AtClause(target=target, anchor="center", position=positions)

    def _center_at_clause(self, target: Any) -> AtClause:
        """Parse ``center at point(x, y)`` and wrap *target*."""
        self._expect(TT.KW_CENTER, "placement anchor")
        self._expect(TT.KW_AT, "placement clause")

        location = self._ident_or_func_call()
        if not isinstance(location, FuncCall) or location.name != "point":
            raise ParseError("Expected point(x, y) after 'center at'", self._peek())
        if len(location.args) != 2:
            raise ParseError("point() requires exactly 2 arguments in V1", self._peek())

        return AtClause(target=target, anchor="center", position=list(location.args))

    def _arg_list_inner(self) -> tuple[list, dict]:
        """Parse comma-separated args inside parentheses.

        Returns (positional_args, keyword_args).
        """
        args: list[Any] = []
        kwargs: dict[str, Any] = {}

        if self._at(TT.RPAREN):
            return args, kwargs

        self._parse_one_arg(args, kwargs)
        while self._at(TT.COMMA):
            self._advance()
            # Handle trailing comma
            if self._at(TT.RPAREN):
                break
            self._parse_one_arg(args, kwargs)

        return args, kwargs


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def parse(source: str) -> Program:
    """Parse MCAD source text and return an AST ``Program`` node."""
    from .lexer import tokenize

    tokens = tokenize(source)
    parser = Parser(tokens)
    return parser.parse()

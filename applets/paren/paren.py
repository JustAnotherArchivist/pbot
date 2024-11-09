#!/usr/bin/env python3
from __future__ import print_function

import sys

from pycparser import c_parser, c_generator, c_ast, plyparser
from pycparser.ply import yacc

with open("paren/stddef") as f:
    STDDEF = f.read()

class CParser(c_parser.CParser):
    def __init__(self, *a, **kw):
        super(CParser, self).__init__(*a, **kw)
        self.cparser = yacc.yacc(
            module=self,
            start='expression',
            debug=kw.get('yacc_debug', False),
            errorlog=yacc.NullLogger(),
            optimize=kw.get('yacc_optimize', True),
            tabmodule=kw.get('yacctab', 'yacctab'))

    def parse(self, text, filename='', debuglevel=0):
        self.clex.filename = filename
        self.clex.reset_lineno()
        self._scope_stack = [dict()]
        self._last_yielded_token = None
        for name in STDDEF.split('\n'):
            if name:
                self._add_typedef_name(name, None)
        return self.cparser.parse(
                input=text,
                lexer=self.clex,
                debug=debuglevel)


class CGenerator(c_generator.CGenerator):
    def _is_simple_node(self, n):
        return isinstance(n, (c_ast.Constant, c_ast.ID, c_ast.FuncCall))

    def visit_UnaryOp(self, n):
        # don't parenthesize an operand to sizeof if it's not a type
        if n.op == 'sizeof':
            if isinstance(n.expr, c_ast.Typename):
                return 'sizeof (%s)' % self.visit(n.expr)
            else:
                return 'sizeof %s' % self._parenthesize_unless_simple(n.expr)
        else:
            operand = self.visit(n.expr)
            if not self._is_simple_node(n.expr) or (n.op == '*' and isinstance(n.expr, c_ast.FuncCall)):
                operand = '(%s)' % operand
            if n.op in ('p++', 'p--'):
                return operand + n.op[1:]
            else:
                return n.op + operand

    def visit_TernaryOp(self, n):
        return '({0}) ? ({1}) : ({2})'.format(
                self.visit(n.cond),
                self.visit(n.iftrue),
                self.visit(n.iffalse))

    def visit_Assignment(self, n):
        return '%s %s %s' % (self.visit(n.lvalue), n.op, self._parenthesize_unless_simple(n.rvalue))


def parenthesize(source):
    parser = CParser(yacc_optimize=False)
    try:
        ast = parser.parse(source, '<input>')
    except plyparser.ParseError as e:
        print("Error: " + e.args[0])
        return
    generator = CGenerator()
    print(generator.visit(ast))


if __name__ == "__main__":
    if len(sys.argv) > 1:
        parenthesize(' '.join(sys.argv[1:]).rstrip(';'))
    elif len(sys.argv) == 1:
        print("Usage: paren <expression>")
    else:
        print('error')

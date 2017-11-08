-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(..., package.seeall)
local maxpc = require("lib.maxpc")
local match, capture, combine = maxpc.import()
local codepoint = maxpc.codepoint

-- Implementation of regular expressions (ASCII only) as defined in Appendix G
-- of "W3C XML Schema Definition Language (XSD) 1.1 Part 2: Datatypes", see:
--
--    https://www.w3.org/TR/xmlschema11-2/#regexs
--
-- The main entry function `regexp.compile' accepts a regular expression
-- string, and returns a predicate function that tests whether a string is part
-- of the language defined by the expression.
--
-- Example:
--    local is_identifier = regexp.compile("[a-zA-Z][a-zA-Z0-9]*")
--    is_identifier("Foo3") -> true
--    is_identifier("7up") -> false
--
-- It uses a combinatory parsing library (MaxPC) to parse a regular expression
-- in the format defined by the specification referenced above, and compiles
-- the denoted regular language to a MaxPC grammar.
--
-- NYI: any Unicode support (i.e. currently a character is a single byte and no
-- category escapes are implemented)

function compile (expr)
   local ast = parse(expr)
   local parser = compile_branches(ast.branches)
   return function (str)
      local _, success, is_eof = maxpc.parse(str, parser)
      return success and is_eof
   end
end

local regExp_parser -- forward definition

function parse (expr)
   local result, success, is_eof = maxpc.parse(expr, regExp_parser)
   if not (success and is_eof) then
      error("Unable to parse regular expression: " .. expr)
   else
      return result
   end
end


-- Parser rules: string -> AST

function capture.regExp ()
   return capture.unpack(
      capture.seq(capture.branch(), combine.any(capture.otherBranch())),
      function (branch, otherBranches)
         local branches = {branch}
         for _, branch in ipairs(otherBranches or {}) do
            table.insert(branches, branch)
         end
         return {branches=branches}
      end
   )
end

function capture.branch ()
   return capture.transform(combine.any(capture.piece()),
                            function (pieces) return {pieces=pieces} end)
end

function capture.otherBranch ()
   return capture.unpack(
      capture.seq(match.equal("|"), capture.branch()),
      function (_, branch) return branch end
   )
end

function capture.piece ()
   return capture.unpack(
      capture.seq(capture.atom(), combine.maybe(capture.quantifier())),
      function (atom, quantifier)
         return {atom=atom, quantifier=quantifier or nil}
      end
   )
end

function capture.quantifier ()
   return combine._or(
      capture.subseq(match.equal("?")),
      capture.subseq(match.equal("*")),
      capture.subseq(match.equal("+")),
      capture.unpack(
         capture.seq(match.equal("{"), capture.quantity(), match.equal("}")),
         function (_, quantity, _) return quantity end
      )
   )
end

function match.digit (s)
   return match.satisfies(
      function (s)
         return ("0123456789"):find(s, 1, true)
      end
   )
end

function capture.quantity ()
   return combine._or(
      capture.quantRange(),
      capture.quantMin(),
      capture.transform(capture.quantExact(),
                        function (n) return {exactly=n} end)
   )
end

function capture.quantRange ()
   return capture.unpack(
      capture.seq(capture.quantExact(),
                  match.equal(","),
                  capture.quantExact()),
      function (min, _, max) return {min=min, max=max} end
   )
end

function capture.quantMin ()
   return capture.unpack(
      capture.seq(capture.quantExact(), match.equal(",")),
      function (min, _) return {min=min} end
   )
end

function capture.quantExact ()
   return capture.transform(
      capture.subseq(combine.some(match.digit())),
      tonumber
   )
end

function capture.atom ()
   return combine._or(
      capture.NormalChar(),
      capture.charClass(),
      capture.subExp()
   )
end

local function regExp_binding (s) return regExp_parser(s) end

function capture.subExp ()
   return capture.unpack(
      capture.seq(match.equal('('), regExp_binding, match.equal(')')),
      function (_, expression, _) return expression end
   )
end

function match.MetaChar ()
   return match.satisfies(
      function (s)
         return (".\\?*+{}()|[]"):find(s, 1, true)
      end
   )
end

function match.NormalChar (s)
   return match._not(match.MetaChar())
end

function capture.NormalChar ()
   return capture.subseq(match.NormalChar())
end

function capture.charClass ()
   return combine._or(
      capture.SingleCharEsc(),
      capture.charClassEsc(),
      capture.charClassExpr(),
      capture.WildcardEsc()
   )
end

function capture.charClassExpr ()
   return capture.unpack(
      capture.seq(match.equal("["), capture.charGroup(), match.equal("]")),
      function (_, charGroup, _) return charGroup end
   )
end

function capture.charGroup ()
   return capture.unpack(
      capture.seq(
         combine._or(capture.negCharGroup(), capture.posCharGroup()),
         combine.maybe(capture.charClassSubtraction())
      ),
      function (group, subtract)
         return {group=group, subtract=subtract or nil}
      end
   )
end

local charClassExpr_parser -- forward declaration
local function charClassExpr_binding (s)
   return charClassExpr_parser(s)
end

function capture.charClassSubtraction ()
   return capture.unpack(
      capture.seq(match.equal("-"), charClassExpr_binding),
      function (_, charClassExpr, _) return charClassExpr end
   )
end

function capture.posCharGroup ()
   return capture.transform(
      combine.some(capture.charGroupPart()),
      function (parts) return {include=parts} end
   )
end

function capture.negCharGroup ()
   return capture.unpack(
      capture.seq(match.equal("^"), capture.posCharGroup()),
      function (_, group) return {exclude=group.include} end
   )
end

function capture.charGroupPart ()
   return combine._or(
      capture.charClassEsc(),
      capture.charRange(),
      capture.singleChar()
   )
end

function capture.singleChar ()
   return combine._or(capture.SingleCharEsc(), capture.singleCharNoEsc())
end

function capture.charRange ()
   local rangeChar = combine.diff(capture.singleChar(), match.equal("-"))
   return capture.unpack(
      capture.seq(rangeChar, match.equal("-"), rangeChar),
      function (from, _, to) return {range={from,to}} end
   )
end

function capture.singleCharNoEsc ()
   local function is_singleCharNoEsc (s)
      return not ("[]"):find(s, 1, true)
   end
   return combine.diff(
      capture.subseq(match.satisfies(is_singleCharNoEsc)),
      -- don’t match the "-" leading a character class subtraction
      match.seq(match.equal("-"), match.equal("["))
   )
end

function capture.charClassEsc ()
   return combine._or(
      capture.MultiCharEsc() --, capture.catEsc(), capture.complEsc()
   )
end

function capture.SingleCharEsc ()
   local function is_SingleCharEsc (s)
      return ("nrt\\|.?*+(){}-[]^"):find(s, 1, true)
   end
   return capture.unpack(
      capture.seq(
         match.equal("\\"),
         capture.subseq(match.satisfies(is_SingleCharEsc))
      ),
      function (_, char) return {escape=char} end
   )
end

-- NYI: catEsc, complEsc

function capture.MultiCharEsc ()
   local function is_multiCharEsc (s)
      return ("sSiIcCdDwW"):find(s, 1, true)
   end
   return capture.unpack(
      capture.seq(
         match.equal("\\"),
         capture.subseq(match.satisfies(is_multiCharEsc))
      ),
      function (_, char) return {escape=char} end
   )
end

function capture.WildcardEsc ()
   return capture.transform(
      match.equal("."),
      function (_) return {escape="."} end
   )
end

regExp_parser = capture.regExp()
charClassExpr_parser = capture.charClassExpr()


-- Compiler rules: AST -> MaxPC parser

function compile_branches (branches)
   local parsers = {}
   for _, branch in ipairs(branches) do
      if branch.pieces then
         table.insert(parsers, compile_pieces(branch.pieces))
      end
   end
   if     #parsers == 0 then return match.eof()
   elseif #parsers == 1 then return parsers[1]
   elseif #parsers  > 1 then return combine._or(unpack(parsers)) end
end

function compile_pieces (pieces)
   local parsers = {}
   for _, piece in ipairs(pieces) do
      local atom_parser = compile_atom(piece.atom)
      if piece.quantifier then
         local quanitify = compile_quantifier(piece.quantifier)
         table.insert(parsers, quanitify(atom_parser))
      else
         table.insert(parsers, atom_parser)
      end
   end
   return match.seq(unpack(parsers))
end

function compile_quantifier (quantifier)
   if     quantifier == "?" then return combine.maybe
   elseif quantifier == "*" then return combine.any
   elseif quantifier == "+" then return combine.some
   elseif quantifier.min and quantifier.max then
      -- [min * parser] .. [max * maybe(parser)]
      return function (parser)
         local parsers = {}
         for n = 1, quantifier.min do
            table.insert(parsers, parser)
         end
         for n = 1, quantifier.max - quantifier.min do
            table.insert(parsers, combine.maybe(parser))
         end
         return match.seq(unpack(parsers))
      end
   elseif quantifier.min then
      -- [min * parser] any(parser)
      return function (parser)
         local parsers = {}
         for n = 1, quantifier.min do
            table.insert(parsers, parser)
         end
         table.insert(parsers, combine.any(parser))
         return match.seq(unpack(parsers))
      end
   elseif quantifier.exactly then
      -- [exactly * parser]
      return function (parser)
         local parsers = {}
         for n = 1, quantifier.exactly do
            table.insert(parsers, parser)
         end
         return match.seq(unpack(parsers))
      end
   else
      error("Invalid quantifier")
   end
end

function compile_atom (atom)
   -- NYI: \i, \I, \c, \C
   local function memberTest (set)
      return function (s) return set:find(s, 1, true) end
   end
   local is_special_escape = memberTest("\\|.-^?*+{}()[]")
   local match_wildcard = function (x) return not memberTest("\n\r") end
   local is_space = memberTest(" \t\n\r")
   local is_digit = memberTest("0123456789")
   local is_word = memberTest("0123456789abcdefghijklmnopqrstiuvwxyzABCDEFGHIJKLMNOPQRSTIUVWXYZ")
   if type(atom) == 'string' then return match.equal(atom)
   elseif atom.escape == "n" then return match.equal("\n")
   elseif atom.escape == "r" then return match.equal("\r")
   elseif atom.escape == "t" then return match.equal("\t")
   elseif atom.escape and is_special_escape(atom.escape) then
      return match.equal(atom.escape)
   elseif atom.escape == "." then
      return match.satisfies(match_wildcard)
   elseif atom.escape == "s" then
      return match.satisfies(is_space)
   elseif atom.escape == "S" then
      return match._not(match.satisfies(is_space))
   elseif atom.escape == "d" then
      return match.satisfies(is_digit)
   elseif atom.escape == "D" then
      return match._not(match.satisfies(is_digit))
   elseif atom.escape == "w" then
      return match.satisfies(is_word)
   elseif atom.escape == "W" then
      return match._not(match.satisfies(is_word))
   elseif atom.group then
      return compile_class(atom.group, atom.subtract)
   elseif atom.range then
      return compile_range(unpack(atom.range))
   elseif atom.branches then
      return compile_branches(atom.branches)
   else
      error("Invalid atom")
   end
end

function compile_class (group, subtract)
   if not subtract then
      return compile_group(group)
   else
      return combine.diff(
         compile_group(group),
         compile_class(subtract.group, subtract.subtract)
      )
   end
end

function compile_group (group)
   local function compile_group_atoms (atoms)
      local parsers = {}
      for _, atom in ipairs(atoms) do
         table.insert(parsers, compile_atom(atom))
      end
      return combine._or(unpack(parsers))
   end
   if group.include then
      return compile_group_atoms(group.include)
   elseif group.exclude then
      return match._not(compile_group_atoms(group.exclude))
   else
      error("Invalid group")
   end
end

function compile_range (start, stop)
   start, stop = codepoint(start), codepoint(stop)
   local function in_range (s)
      s = codepoint(s)
      return start <= s and s <= stop
   end
   return match.satisfies(in_range)
end


-- Tests

local function test (o)
   local match = compile(o.regexp)
   for _, input in ipairs(o.accept) do
      assert(match(input), o.regexp .. " should match " .. input)
   end
   for _, input in ipairs(o.reject) do
      assert(not match(input), o.regexp .. " should not match " .. input)
   end
end

function selftest ()
   test {regexp="[a-zA-Z][a-zA-Z0-9]*",
         accept={"Foo3", "baz"},
         reject={"7Up", "123", "äöü", ""}}

   test {regexp="",
         accept={""},
         reject={"foo"}}

   test {regexp="abc",
         accept={"abc"},
         reject={"abcd", "0abc", ""}}

   test {regexp="a[bc]",
         accept={"ab", "ac"},
         reject={"abcd", "0abc", "aa", ""}}

   test {regexp="\\n+",
         accept={"\n", "\n\n\n"},
         reject={"", "\n\n\t", "\naa"}}

   test {regexp="(foo|bar)?",
         accept={"foo", "bar", ""},
         reject={"foobar"}}

   test {regexp="foo|bar|baz",
         accept={"foo", "bar", "baz"},
         reject={"", "fo"}}

   test {regexp="\\]",
         accept={"]"},
         reject={"", "\\]"}}

   test {regexp="\\d{3,}",
         accept={"123", "45678910"},
         reject={"", "12", "foo"}}

   test {regexp="[^\\d]{3,5}",
         accept={"foo", "....", ".-.-."},
         reject={"", "foobar", "123", "4567", "45678"}}

   test {regexp="[abc-[ab]]{3}",
         accept={"ccc"},
         reject={"", "abc"}}
end
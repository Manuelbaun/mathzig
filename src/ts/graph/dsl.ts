/**
 * Graph DSL sugar → GraphDefinition JSON lowering.
 *
 * Sugar only: no second execution path. The lowered GraphDefinition is loaded
 * by the existing GraphRunner.
 *
 * Grammar (informal):
 *
 *   program     := 'graph' '{' stmt* '}' | stmt*
 *   stmt        := param_stmt | out_stmt | input_stmt | const_stmt | assign_stmt
 *   param_stmt  := 'param' ident '=' number ';'
 *   out_stmt    := 'out' ident (',' ident)* ';'
 *   input_stmt  := 'input' ident (':' kind)? ';'
 *   const_stmt  := 'const' ident '=' literal ';'
 *   assign_stmt := ident (':' kind)? '=' expr ';'
 *
 * Free identifiers on an assignment RHS (not params, not prior node names,
 * not call callees, not reserved words) become graph input nodes. The last
 * assignment is the default output unless `out` is declared. Function-call
 * RHS that matches a library entry becomes a `wasm` node; otherwise the
 * whole RHS is an `expr` node.
 */

import type {
  GraphDefinition,
  GraphEdge,
  GraphNode,
  GraphRef,
  GraphValue,
  NodeManifest,
} from "./schema";
import { normalizePortKind, type PortKind } from "./value_transfer";
import {
  MAX_IDENTIFIER_LEN,
  MAX_NESTING_DEPTH,
  MAX_SOURCE_BYTES,
  MAX_TOKEN_COUNT,
} from "./limits";
import { MathZigLoadError, type ErrorContext } from "./load_error";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

export type DslSourcePosition = {
  line: number;
  col: number;
  offset: number;
};

/**
 * DSL parse failure — typed C3 load error (`phase: "dsl"`).
 * Preserves line/col/offset for existing call sites.
 */
export class DslError extends MathZigLoadError {
  readonly line: number;
  readonly col: number;
  readonly offset: number;

  constructor(
    message: string,
    pos: DslSourcePosition,
    opts?: { code?: string; context?: ErrorContext },
  ) {
    const code = opts?.code ?? "DslParseError";
    super("dsl", code, `${message} (line ${pos.line}, col ${pos.col})`, {
      position: { byte: pos.offset, line: pos.line, col: pos.col },
      context: opts?.context,
    });
    this.name = "DslError";
    this.line = pos.line;
    this.col = pos.col;
    this.offset = pos.offset;
  }
}

/** Optional named library nodes resolved from bare function-call assignments. */
export type DslLibraryEntry = {
  wasm: Uint8Array | ArrayBuffer | string;
  manifest: NodeManifest;
  /** Override runtime param defaults. */
  params?: Record<string, number>;
};

export type ParseGraphDslOptions = {
  /**
   * Map of library function name → precompiled wasm node.
   * When an assignment is exactly `name = libfn(arg1, arg2, ...)`, and `libfn`
   * is registered here, the node becomes type `wasm` instead of `expr`.
   */
  library?: Record<string, DslLibraryEntry>;
};

export type ParseGraphDslResult = {
  definition: GraphDefinition;
  /** Declared graph-level param defaults (applied onto every node that uses them). */
  params: Record<string, number>;
  /** Output names in declaration order. */
  outputNames: string[];
  /** Input names in first-seen order. */
  inputNames: string[];
};

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

type TokenKind =
  | "ident"
  | "number"
  | "string"
  | "lbrace"
  | "rbrace"
  | "lparen"
  | "rparen"
  | "lbracket"
  | "rbracket"
  | "semi"
  | "comma"
  | "colon"
  | "eq"
  | "op"
  | "eof";

type Token = {
  kind: TokenKind;
  text: string;
  line: number;
  col: number;
  offset: number;
};

const KEYWORDS = new Set([
  "graph",
  "param",
  "out",
  "input",
  "const",
  "true",
  "false",
  "null",
  "nan",
  "inf",
]);

/** Words that never become free graph inputs when seen in expressions. */
const RESERVED_EXPR_IDS = new Set([
  "true",
  "false",
  "null",
  "nan",
  "inf",
  "i", // imaginary unit suffix / literal in MathZig
  "pi",
  "e",
  "where",
  "and",
  "or",
  "not",
  "between",
  "in",
  "as",
]);

const PORT_KINDS = new Set([
  "number",
  "scalar",
  "boolean",
  "bool",
  "matrix",
  "complex",
  "record",
  "string",
  "series",
  "any",
]);

function posOf(tok: Token): DslSourcePosition {
  return { line: tok.line, col: tok.col, offset: tok.offset };
}

function tokenize(source: string): Token[] {
  if (source.length > MAX_SOURCE_BYTES) {
    throw new DslError(
      `DSL source exceeds MAX_SOURCE_BYTES (${MAX_SOURCE_BYTES})`,
      { line: 1, col: 1, offset: 0 },
      { code: "SourceTooLarge" },
    );
  }

  const tokens: Token[] = [];
  let i = 0;
  let line = 1;
  let col = 1;
  let nesting = 0;

  const peek = (n = 0) => source[i + n] ?? "";
  const advance = (): string => {
    const ch = source[i] ?? "";
    i += 1;
    if (ch === "\n") {
      line += 1;
      col = 1;
    } else {
      col += 1;
    }
    return ch;
  };

  const pushTok = (tok: Token) => {
    if (tokens.length >= MAX_TOKEN_COUNT) {
      throw new DslError(
        `DSL token count exceeds MAX_TOKEN_COUNT (${MAX_TOKEN_COUNT})`,
        { line: tok.line, col: tok.col, offset: tok.offset },
        { code: "TokenLimitExceeded" },
      );
    }
    tokens.push(tok);
  };

  while (i < source.length) {
    const startLine = line;
    const startCol = col;
    const startOff = i;
    const ch = peek();

    // Whitespace
    if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") {
      advance();
      continue;
    }

    // Line comment //
    if (ch === "/" && peek(1) === "/") {
      while (i < source.length && peek() !== "\n") advance();
      continue;
    }

    // Block comment /* */
    if (ch === "/" && peek(1) === "*") {
      advance();
      advance();
      while (i < source.length && !(peek() === "*" && peek(1) === "/")) {
        advance();
      }
      if (i >= source.length) {
        throw new DslError("Unterminated block comment", {
          line: startLine,
          col: startCol,
          offset: startOff,
        });
      }
      advance();
      advance();
      continue;
    }

    // String
    if (ch === '"' || ch === "'") {
      const quote = advance();
      let text = quote;
      while (i < source.length && peek() !== quote) {
        if (peek() === "\\") {
          text += advance();
          if (i < source.length) text += advance();
        } else {
          if (peek() === "\n") {
            throw new DslError("Unterminated string", {
              line: startLine,
              col: startCol,
              offset: startOff,
            });
          }
          text += advance();
        }
      }
      if (i >= source.length) {
        throw new DslError("Unterminated string", {
          line: startLine,
          col: startCol,
          offset: startOff,
        });
      }
      text += advance();
      pushTok({ kind: "string", text, line: startLine, col: startCol, offset: startOff });
      continue;
    }

    // Number (incl. leading dot fractions and scientific notation)
    if (
      isDigit(ch) ||
      (ch === "." && isDigit(peek(1))) ||
      (ch === "-" && (isDigit(peek(1)) || (peek(1) === "." && isDigit(peek(2)))))
    ) {
      // Only treat leading '-' as part of a number when previous token is not
      // an expression value (handled at a higher level). Tokenizer always
      // emits '-' as op and number separately when ambiguous; for param
      // defaults we re-parse signed numbers in the parser.
      if (ch === "-") {
        // Leave unary minus as op; parser of param/const handles it.
        pushTok({ kind: "op", text: advance(), line: startLine, col: startCol, offset: startOff });
        continue;
      }
      let text = "";
      while (isDigit(peek())) text += advance();
      if (peek() === ".") {
        text += advance();
        while (isDigit(peek())) text += advance();
      }
      if (peek() === "e" || peek() === "E") {
        text += advance();
        if (peek() === "+" || peek() === "-") text += advance();
        if (!isDigit(peek())) {
          throw new DslError("Malformed exponent in number", {
            line: startLine,
            col: startCol,
            offset: startOff,
          });
        }
        while (isDigit(peek())) text += advance();
      }
      pushTok({ kind: "number", text, line: startLine, col: startCol, offset: startOff });
      continue;
    }

    // Identifier / keyword
    if (isIdentStart(ch)) {
      let text = "";
      while (isIdentContinue(peek())) text += advance();
      if (text.length > MAX_IDENTIFIER_LEN) {
        throw new DslError(
          `Identifier exceeds MAX_IDENTIFIER_LEN (${MAX_IDENTIFIER_LEN})`,
          { line: startLine, col: startCol, offset: startOff },
          { code: "IdentifierTooLong", context: { field: text.slice(0, 32) } },
        );
      }
      pushTok({ kind: "ident", text, line: startLine, col: startCol, offset: startOff });
      continue;
    }

    // Multi-char ops we treat as opaque expression ops when scanning expr text
    const two = ch + peek(1);
    if (
      two === "==" ||
      two === "!=" ||
      two === "<=" ||
      two === ">=" ||
      two === "&&" ||
      two === "||" ||
      two === "**" ||
      two === ".."
    ) {
      advance();
      advance();
      pushTok({ kind: "op", text: two, line: startLine, col: startCol, offset: startOff });
      continue;
    }

    switch (ch) {
      case "{":
        advance();
        nesting += 1;
        if (nesting > MAX_NESTING_DEPTH) {
          throw new DslError(
            `Nesting depth exceeds MAX_NESTING_DEPTH (${MAX_NESTING_DEPTH})`,
            { line: startLine, col: startCol, offset: startOff },
            { code: "NestingTooDeep" },
          );
        }
        pushTok({ kind: "lbrace", text: ch, line: startLine, col: startCol, offset: startOff });
        continue;
      case "}":
        advance();
        nesting = Math.max(0, nesting - 1);
        pushTok({ kind: "rbrace", text: ch, line: startLine, col: startCol, offset: startOff });
        continue;
      case "(":
        advance();
        nesting += 1;
        if (nesting > MAX_NESTING_DEPTH) {
          throw new DslError(
            `Nesting depth exceeds MAX_NESTING_DEPTH (${MAX_NESTING_DEPTH})`,
            { line: startLine, col: startCol, offset: startOff },
            { code: "NestingTooDeep" },
          );
        }
        pushTok({ kind: "lparen", text: ch, line: startLine, col: startCol, offset: startOff });
        continue;
      case ")":
        advance();
        nesting = Math.max(0, nesting - 1);
        pushTok({ kind: "rparen", text: ch, line: startLine, col: startCol, offset: startOff });
        continue;
      case "[":
        advance();
        nesting += 1;
        if (nesting > MAX_NESTING_DEPTH) {
          throw new DslError(
            `Nesting depth exceeds MAX_NESTING_DEPTH (${MAX_NESTING_DEPTH})`,
            { line: startLine, col: startCol, offset: startOff },
            { code: "NestingTooDeep" },
          );
        }
        pushTok({ kind: "lbracket", text: ch, line: startLine, col: startCol, offset: startOff });
        continue;
      case "]":
        advance();
        nesting = Math.max(0, nesting - 1);
        pushTok({ kind: "rbracket", text: ch, line: startLine, col: startCol, offset: startOff });
        continue;
      case ";":
        advance();
        pushTok({ kind: "semi", text: ch, line: startLine, col: startCol, offset: startOff });
        continue;
      case ",":
        advance();
        pushTok({ kind: "comma", text: ch, line: startLine, col: startCol, offset: startOff });
        continue;
      case ":":
        advance();
        pushTok({ kind: "colon", text: ch, line: startLine, col: startCol, offset: startOff });
        continue;
      case "=":
        advance();
        pushTok({ kind: "eq", text: ch, line: startLine, col: startCol, offset: startOff });
        continue;
      default:
        // Treat other punctuation as expression operators (+ - * / ^ % ! < > . etc.)
        if ("+-*/^%!.<>?@#&|~".includes(ch)) {
          advance();
          pushTok({ kind: "op", text: ch, line: startLine, col: startCol, offset: startOff });
          continue;
        }
        throw new DslError(`Unexpected character '${ch}'`, {
          line: startLine,
          col: startCol,
          offset: startOff,
        });
    }
  }

  pushTok({ kind: "eof", text: "", line, col, offset: i });
  return tokens;
}

function isDigit(ch: string): boolean {
  return ch >= "0" && ch <= "9";
}

function isIdentStart(ch: string): boolean {
  return (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || ch === "_";
}

function isIdentContinue(ch: string): boolean {
  return isIdentStart(ch) || isDigit(ch);
}

// ---------------------------------------------------------------------------
// AST (statement-level)
// ---------------------------------------------------------------------------

type Stmt =
  | { kind: "param"; name: string; value: number; pos: DslSourcePosition }
  | { kind: "out"; names: string[]; pos: DslSourcePosition }
  | { kind: "input"; name: string; portKind?: PortKind; pos: DslSourcePosition }
  | { kind: "const"; name: string; value: GraphValue; portKind?: PortKind; pos: DslSourcePosition }
  | {
      kind: "assign";
      name: string;
      portKind?: PortKind;
      /** Raw RHS text preserved for expr nodes. */
      exprText: string;
      /** Tokens spanning the RHS (for free-id / library analysis). */
      rhsTokens: Token[];
      pos: DslSourcePosition;
    };

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

class Parser {
  private i = 0;
  constructor(
    private readonly tokens: Token[],
    private readonly source: string,
  ) {}

  parse(): Stmt[] {
    // Optional `graph { ... }` wrapper
    if (this.checkIdent("graph")) {
      this.bump();
      this.expect("lbrace", "Expected '{' after 'graph'");
      const stmts = this.parseStmtsUntil("rbrace");
      this.expect("rbrace", "Expected '}' to close graph block");
      if (!this.at("eof")) {
        throw new DslError("Unexpected tokens after graph block", posOf(this.cur()));
      }
      return stmts;
    }
    return this.parseStmtsUntil("eof");
  }

  private parseStmtsUntil(end: TokenKind): Stmt[] {
    const stmts: Stmt[] = [];
    while (!this.at(end) && !this.at("eof")) {
      stmts.push(this.parseStmt());
    }
    return stmts;
  }

  private parseStmt(): Stmt {
    if (this.checkIdent("param")) return this.parseParam();
    if (this.checkIdent("out")) return this.parseOut();
    if (this.checkIdent("input")) return this.parseInput();
    if (this.checkIdent("const")) return this.parseConst();
    return this.parseAssign();
  }

  private parseParam(): Stmt {
    const pos = posOf(this.cur());
    this.bump(); // param
    const nameTok = this.expect("ident", "Expected parameter name after 'param'");
    this.expect("eq", "Expected '=' after parameter name");
    const value = this.parseSignedNumber("parameter default");
    this.expect("semi", "Expected ';' after parameter declaration");
    return { kind: "param", name: nameTok.text, value, pos };
  }

  private parseOut(): Stmt {
    const pos = posOf(this.cur());
    this.bump(); // out
    const names: string[] = [];
    names.push(this.expect("ident", "Expected output name after 'out'").text);
    while (this.at("comma")) {
      this.bump();
      names.push(this.expect("ident", "Expected output name after ','").text);
    }
    this.expect("semi", "Expected ';' after out declaration");
    return { kind: "out", names, pos };
  }

  private parseInput(): Stmt {
    const pos = posOf(this.cur());
    this.bump(); // input
    const nameTok = this.expect("ident", "Expected input name after 'input'");
    let portKind: PortKind | undefined;
    if (this.at("colon")) {
      this.bump();
      portKind = this.parseKind();
    }
    this.expect("semi", "Expected ';' after input declaration");
    return { kind: "input", name: nameTok.text, portKind, pos };
  }

  private parseConst(): Stmt {
    const pos = posOf(this.cur());
    this.bump(); // const
    const nameTok = this.expect("ident", "Expected name after 'const'");
    let portKind: PortKind | undefined;
    if (this.at("colon")) {
      this.bump();
      portKind = this.parseKind();
    }
    this.expect("eq", "Expected '=' after const name");
    const value = this.parseLiteralValue();
    this.expect("semi", "Expected ';' after const declaration");
    return { kind: "const", name: nameTok.text, value, portKind, pos };
  }

  private parseAssign(): Stmt {
    const nameTok = this.expect("ident", "Expected statement or assignment");
    if (KEYWORDS.has(nameTok.text) && nameTok.text !== "true" && nameTok.text !== "false") {
      // graph/param/out/input/const already handled; other keywords invalid as lhs
      throw new DslError(`'${nameTok.text}' cannot be used as an assignment target`, posOf(nameTok));
    }
    const pos = posOf(nameTok);
    let portKind: PortKind | undefined;
    if (this.at("colon")) {
      this.bump();
      portKind = this.parseKind();
    }
    this.expect("eq", `Expected '=' after '${nameTok.text}'`);
    const rhsTokens = this.consumeExpressionTokens();
    if (rhsTokens.length === 0) {
      throw new DslError("Expected expression on right-hand side", posOf(this.cur()));
    }
    this.expect("semi", "Expected ';' after assignment");
    const first = rhsTokens[0]!;
    const last = rhsTokens[rhsTokens.length - 1]!;
    const exprText = this.source.slice(first.offset, last.offset + last.text.length).trim();
    return {
      kind: "assign",
      name: nameTok.text,
      portKind,
      exprText,
      rhsTokens,
      pos,
    };
  }

  /**
   * Consume tokens that form one RHS expression, stopping at the top-level
   * statement terminator ('; / closing brace). Tracks nesting so matrices,
   * records, and calls parse as a single expression.
   */
  private consumeExpressionTokens(): Token[] {
    const out: Token[] = [];
    let depthParen = 0;
    let depthBrace = 0;
    let depthBracket = 0;

    while (!this.at("eof")) {
      const t = this.cur();
      if (
        depthParen === 0 &&
        depthBrace === 0 &&
        depthBracket === 0 &&
        (t.kind === "semi" || t.kind === "rbrace")
      ) {
        break;
      }
      if (t.kind === "lparen") depthParen += 1;
      if (t.kind === "rparen") depthParen -= 1;
      if (t.kind === "lbrace") depthBrace += 1;
      if (t.kind === "rbrace") depthBrace -= 1;
      if (t.kind === "lbracket") depthBracket += 1;
      if (t.kind === "rbracket") depthBracket -= 1;
      if (depthParen < 0 || depthBrace < 0 || depthBracket < 0) {
        throw new DslError(`Unbalanced '${t.text}' in expression`, posOf(t));
      }
      out.push(t);
      this.bump();
    }
    return out;
  }

  private parseKind(): PortKind {
    const tok = this.expect("ident", "Expected port kind after ':'");
    if (!PORT_KINDS.has(tok.text)) {
      throw new DslError(
        `Unknown port kind '${tok.text}'. Expected one of: ${[...PORT_KINDS].join(", ")}`,
        posOf(tok),
      );
    }
    return normalizePortKind(tok.text);
  }

  private parseSignedNumber(label: string): number {
    let sign = 1;
    if (this.at("op") && this.cur().text === "-") {
      sign = -1;
      this.bump();
    } else if (this.at("op") && this.cur().text === "+") {
      this.bump();
    }
    if (this.checkIdent("nan")) {
      this.bump();
      return sign * Number.NaN;
    }
    if (this.checkIdent("inf")) {
      this.bump();
      return sign * Number.POSITIVE_INFINITY;
    }
    const num = this.expect("number", `Expected ${label} number`);
    const n = Number(num.text);
    if (!Number.isFinite(n) && num.text.toLowerCase() !== "nan") {
      // inf already handled; other non-finite is still a valid token parse failure
    }
    return sign * n;
  }

  private parseLiteralValue(): GraphValue {
    if (this.checkIdent("true")) {
      this.bump();
      return true;
    }
    if (this.checkIdent("false")) {
      this.bump();
      return false;
    }
    if (this.at("string")) {
      const t = this.bump();
      return t.text.slice(1, -1);
    }
    // number (optionally signed)
    return this.parseSignedNumber("const");
  }

  private at(kind: TokenKind): boolean {
    return this.cur().kind === kind;
  }

  private checkIdent(text: string): boolean {
    const t = this.cur();
    return t.kind === "ident" && t.text === text;
  }

  private cur(): Token {
    return this.tokens[this.i] ?? this.tokens[this.tokens.length - 1]!;
  }

  private bump(): Token {
    const t = this.cur();
    if (t.kind !== "eof") this.i += 1;
    return t;
  }

  private expect(kind: TokenKind, message: string): Token {
    const t = this.cur();
    if (t.kind !== kind) {
      throw new DslError(message, posOf(t));
    }
    return this.bump();
  }
}

// ---------------------------------------------------------------------------
// Expression analysis (free ids + pure literal + single call)
// ---------------------------------------------------------------------------

type ExprAnalysis = {
  /** Identifiers that may be inputs/params/node refs (not call callees). */
  freeIds: string[];
  /** If RHS is exactly `fn(arg1, arg2, ...)` — callee name and arg free-ids in order. */
  singleCall: { callee: string; argIds: string[] } | null;
  /** If RHS is a pure numeric/bool/string literal. */
  pureLiteral: GraphValue | null;
};

function analyzeExpr(tokens: Token[]): ExprAnalysis {
  const freeIds: string[] = [];
  const seen = new Set<string>();

  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i]!;
    if (t.kind !== "ident") continue;
    if (RESERVED_EXPR_IDS.has(t.text)) continue;

    // Skip field / method names after '.'
    const prev = tokens[i - 1];
    if (prev && prev.kind === "op" && prev.text === ".") continue;

    // Call callee: ident immediately followed by '('
    const next = tokens[i + 1];
    if (next && next.kind === "lparen") continue;

    // Record field names in `{ a: 10, b: 20 }` — ident followed by ':'
    // at brace depth. Conservative: skip ident immediately before ':' when
    // previous non-ws structure suggests record. Safer heuristic: if next is
    // colon AND (prev is lbrace or comma), treat as field key.
    if (next && next.kind === "colon") {
      if (!prev || prev.kind === "lbrace" || prev.kind === "comma") continue;
    }

    if (!seen.has(t.text)) {
      seen.add(t.text);
      freeIds.push(t.text);
    }
  }

  const singleCall = matchSingleCall(tokens);
  const pureLiteral = matchPureLiteral(tokens);

  return { freeIds, singleCall, pureLiteral };
}

function matchSingleCall(
  tokens: Token[],
): { callee: string; argIds: string[] } | null {
  if (tokens.length < 3) return null;
  if (tokens[0]!.kind !== "ident") return null;
  if (tokens[1]!.kind !== "lparen") return null;
  if (tokens[tokens.length - 1]!.kind !== "rparen") return null;

  // Ensure the outer paren pair wraps the whole call (no trailing ops).
  let depth = 0;
  for (let i = 1; i < tokens.length; i++) {
    if (tokens[i]!.kind === "lparen") depth += 1;
    if (tokens[i]!.kind === "rparen") depth -= 1;
    if (depth === 0 && i !== tokens.length - 1) return null;
  }
  if (depth !== 0) return null;

  const callee = tokens[0]!.text;
  const inner = tokens.slice(2, -1);
  const argIds: string[] = [];

  // Split top-level args; each arg that is a single identifier is an edge port.
  if (inner.length === 0) {
    return { callee, argIds };
  }

  let start = 0;
  let dParen = 0;
  let dBrace = 0;
  let dBracket = 0;
  const flush = (end: number) => {
    const slice = inner.slice(start, end).filter((t) => t.kind !== "eof");
    if (slice.length === 1 && slice[0]!.kind === "ident") {
      argIds.push(slice[0]!.text);
    } else if (slice.length > 0) {
      // Complex arg — collect free ids for wiring later via freeIds path.
      // Mark with empty string? Better: don't use argIds for complex; fall
      // back to expr node. For library wasm nodes, only pure-ident args work.
      argIds.push(""); // signal non-ident arg
    }
  };

  for (let i = 0; i < inner.length; i++) {
    const t = inner[i]!;
    if (t.kind === "lparen") dParen += 1;
    else if (t.kind === "rparen") dParen -= 1;
    else if (t.kind === "lbrace") dBrace += 1;
    else if (t.kind === "rbrace") dBrace -= 1;
    else if (t.kind === "lbracket") dBracket += 1;
    else if (t.kind === "rbracket") dBracket -= 1;
    else if (t.kind === "comma" && dParen === 0 && dBrace === 0 && dBracket === 0) {
      flush(i);
      start = i + 1;
    }
  }
  flush(inner.length);

  return { callee, argIds };
}

function matchPureLiteral(tokens: Token[]): GraphValue | null {
  if (tokens.length === 0) return null;

  // true / false
  if (tokens.length === 1 && tokens[0]!.kind === "ident") {
    if (tokens[0]!.text === "true") return true;
    if (tokens[0]!.text === "false") return false;
  }

  // string
  if (tokens.length === 1 && tokens[0]!.kind === "string") {
    return tokens[0]!.text.slice(1, -1);
  }

  // number or signed number
  if (tokens.length === 1 && tokens[0]!.kind === "number") {
    return Number(tokens[0]!.text);
  }
  if (
    tokens.length === 2 &&
    tokens[0]!.kind === "op" &&
    (tokens[0]!.text === "-" || tokens[0]!.text === "+") &&
    tokens[1]!.kind === "number"
  ) {
    const n = Number(tokens[1]!.text);
    return tokens[0]!.text === "-" ? -n : n;
  }
  if (tokens.length === 1 && tokens[0]!.kind === "ident" && tokens[0]!.text === "nan") {
    return Number.NaN;
  }
  if (tokens.length === 1 && tokens[0]!.kind === "ident" && tokens[0]!.text === "inf") {
    return Number.POSITIVE_INFINITY;
  }
  if (
    tokens.length === 2 &&
    tokens[0]!.kind === "op" &&
    tokens[0]!.text === "-" &&
    tokens[1]!.kind === "ident" &&
    tokens[1]!.text === "inf"
  ) {
    return Number.NEGATIVE_INFINITY;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Lowering
// ---------------------------------------------------------------------------

/**
 * Parse graph DSL source and lower it to a GraphDefinition suitable for
 * GraphRunner.load(). Pure: no I/O, no compilation.
 *
 * Trust boundary S1: input is a **JS string**. For raw bytes use
 * {@link parseGraphDslBytes} (UTF-8 decode policy).
 */
export function parseGraphDsl(
  source: string,
  options: ParseGraphDslOptions = {},
): ParseGraphDslResult {
  const tokens = tokenize(source);
  const stmts = new Parser(tokens, source).parse();
  return lowerStmts(stmts, options);
}

/**
 * S1 byte-boundary entry: decode UTF-8, reject invalid sequences with a typed
 * error (`InvalidUtf8`), then parse as DSL text.
 */
export function parseGraphDslBytes(
  bytes: Uint8Array | ArrayBuffer,
  options: ParseGraphDslOptions = {},
): ParseGraphDslResult {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  if (view.byteLength > MAX_SOURCE_BYTES) {
    throw new DslError(
      `DSL source exceeds MAX_SOURCE_BYTES (${MAX_SOURCE_BYTES})`,
      { line: 1, col: 1, offset: 0 },
      { code: "SourceTooLarge" },
    );
  }
  let text: string;
  try {
    // fatal: true → TypeError on invalid UTF-8 sequences
    text = new TextDecoder("utf-8", { fatal: true }).decode(view);
  } catch (e) {
    throw new DslError(
      "Invalid UTF-8 in DSL source bytes",
      { line: 1, col: 1, offset: 0 },
      { code: "InvalidUtf8" },
    );
  }
  return parseGraphDsl(text, options);
}

/** Convenience: parse and return only the GraphDefinition. */
export function dslToGraphDefinition(
  source: string,
  options: ParseGraphDslOptions = {},
): GraphDefinition {
  return parseGraphDsl(source, options).definition;
}

function lowerStmts(stmts: Stmt[], options: ParseGraphDslOptions): ParseGraphDslResult {
  const library = options.library ?? {};
  const params: Record<string, number> = {};
  const explicitOutputs: string[] = [];
  const nodes: GraphNode[] = [];
  const edges: GraphEdge[] = [];
  const nodeIds = new Set<string>();
  /** Declared/known output kind per node id (for inputKinds inheritance). */
  const knownOutputKind = new Map<string, PortKind>();
  const inputKinds = new Map<string, PortKind>();
  const inputOrder: string[] = [];
  const assignOrder: string[] = [];

  const declareNode = (id: string, pos: DslSourcePosition) => {
    if (nodeIds.has(id) || params[id] !== undefined) {
      throw new DslError(`Duplicate name '${id}'`, pos);
    }
    nodeIds.add(id);
  };

  const ensureInput = (name: string, kind?: PortKind, pos?: DslSourcePosition) => {
    if (params[name] !== undefined) {
      if (pos) throw new DslError(`'${name}' is already declared as a param`, pos);
      return;
    }
    if (nodeIds.has(name)) return; // already a node (including prior input)
    if (!inputOrder.includes(name)) inputOrder.push(name);
    if (kind) inputKinds.set(name, kind);
  };

  const resolveRefKind = (id: string): PortKind => {
    if (knownOutputKind.has(id)) return knownOutputKind.get(id)!;
    if (inputKinds.has(id)) return inputKinds.get(id)!;
    return "number";
  };

  // First pass: collect params, explicit inputs/consts, and check names.
  for (const stmt of stmts) {
    switch (stmt.kind) {
      case "param": {
        if (params[stmt.name] !== undefined || nodeIds.has(stmt.name)) {
          throw new DslError(`Duplicate param '${stmt.name}'`, stmt.pos);
        }
        if (!Number.isFinite(stmt.value)) {
          throw new DslError(`Param '${stmt.name}' default must be a finite number`, stmt.pos);
        }
        params[stmt.name] = stmt.value;
        break;
      }
      case "out": {
        for (const n of stmt.names) {
          if (!explicitOutputs.includes(n)) explicitOutputs.push(n);
        }
        break;
      }
      case "input": {
        declareNode(stmt.name, stmt.pos);
        if (!inputOrder.includes(stmt.name)) inputOrder.push(stmt.name);
        if (stmt.portKind) inputKinds.set(stmt.name, stmt.portKind);
        if (stmt.portKind) knownOutputKind.set(stmt.name, stmt.portKind);
        nodes.push({
          id: stmt.name,
          type: "input",
          name: stmt.name,
          kind: stmt.portKind,
        });
        break;
      }
      case "const": {
        declareNode(stmt.name, stmt.pos);
        const k =
          stmt.portKind ??
          (typeof stmt.value === "boolean"
            ? "boolean"
            : typeof stmt.value === "string"
              ? "string"
              : "number");
        knownOutputKind.set(stmt.name, k);
        nodes.push({
          id: stmt.name,
          type: "const",
          value: stmt.value,
          kind: stmt.portKind,
        });
        break;
      }
      case "assign": {
        // Deferred to second pass for free-id analysis, but reserve name.
        declareNode(stmt.name, stmt.pos);
        assignOrder.push(stmt.name);
        // Pre-register annotated output kinds so later nodes can inherit.
        if (stmt.portKind) knownOutputKind.set(stmt.name, stmt.portKind);
        break;
      }
    }
  }

  // Second pass: lower assignments.
  for (const stmt of stmts) {
    if (stmt.kind !== "assign") continue;

    const analysis = analyzeExpr(stmt.rhsTokens);

    // Pure literal → const node
    if (analysis.pureLiteral !== null && analysis.freeIds.length === 0) {
      const lit = analysis.pureLiteral;
      const k =
        stmt.portKind ??
        (typeof lit === "boolean" ? "boolean" : typeof lit === "string" ? "string" : "number");
      knownOutputKind.set(stmt.name, k);
      nodes.push({
        id: stmt.name,
        type: "const",
        value: lit,
        kind: stmt.portKind,
      });
      continue;
    }

    // Library single-call → wasm node (only when all args are simple idents)
    if (
      analysis.singleCall &&
      library[analysis.singleCall.callee] &&
      analysis.singleCall.argIds.every((a) => a.length > 0)
    ) {
      const entry = library[analysis.singleCall.callee]!;
      const call = analysis.singleCall;
      const manifestInputs = entry.manifest.inputs ?? [];
      if (call.argIds.length !== manifestInputs.length) {
        throw new DslError(
          `Library node '${call.callee}' expects ${manifestInputs.length} argument(s), got ${call.argIds.length}`,
          stmt.pos,
        );
      }
      const outKind = normalizePortKind(
        entry.manifest.output?.kind ?? entry.manifest.output?.result_tag ?? "number",
      );
      knownOutputKind.set(stmt.name, stmt.portKind ?? outKind);
      nodes.push({
        id: stmt.name,
        type: "wasm",
        wasm: entry.wasm,
        manifest: entry.manifest,
        params: entry.params ? { ...entry.params } : undefined,
      });
      for (let i = 0; i < call.argIds.length; i++) {
        const arg = call.argIds[i]!;
        const port = manifestInputs[i]!.name;
        wireRef(arg, stmt.name, port, params, nodeIds, ensureInput, edges, stmt.pos);
      }
      continue;
    }

    // Default: expr node
    const usedParams: Record<string, number> = {};
    const inputs: string[] = [];
    const inputKindsArr: PortKind[] = [];

    for (const id of analysis.freeIds) {
      if (Object.hasOwn(params, id)) {
        usedParams[id] = params[id]!;
        continue;
      }
      // Self-reference is a cycle / error
      if (id === stmt.name) {
        throw new DslError(`Node '${stmt.name}' cannot reference itself`, stmt.pos);
      }
      if (!nodeIds.has(id)) {
        ensureInput(id);
      }
      if (!inputs.includes(id)) {
        inputs.push(id);
        // Inherit producer output kind when known (matrix/complex chains).
        inputKindsArr.push(resolveRefKind(id));
      }
    }

    const outKind = stmt.portKind ?? "number";
    knownOutputKind.set(stmt.name, outKind);

    const node: GraphNode = {
      id: stmt.name,
      type: "expr",
      expr: stmt.exprText,
      inputs: inputs.length > 0 ? inputs : undefined,
      inputKinds: inputs.length > 0 ? inputKindsArr : undefined,
      params: Object.keys(usedParams).length > 0 ? usedParams : undefined,
      outputKind: stmt.portKind,
    };
    nodes.push(node);

    for (const port of inputs) {
      wireRef(port, stmt.name, port, params, nodeIds, ensureInput, edges, stmt.pos);
    }
  }

  // Materialize free inputs that were only referenced (not declared via `input`).
  for (const name of inputOrder) {
    if (nodes.some((n) => n.id === name)) continue;
    nodes.push({
      id: name,
      type: "input",
      name,
      kind: inputKinds.get(name),
    });
    nodeIds.add(name);
  }

  // Outputs
  let outputNames = explicitOutputs;
  if (outputNames.length === 0) {
    if (assignOrder.length === 0) {
      // Fall back to last non-input node, or empty.
      const last = [...nodes].reverse().find((n) => n.type !== "input");
      if (last) outputNames = [last.id];
    } else {
      outputNames = [assignOrder[assignOrder.length - 1]!];
    }
  }

  for (const outName of outputNames) {
    if (!nodeIds.has(outName) && !nodes.some((n) => n.id === outName)) {
      // Find matching — nodeIds should have it
      const exists = nodes.some((n) => n.id === outName);
      if (!exists) {
        throw new DslError(`Output '${outName}' is not defined`, { line: 1, col: 1, offset: 0 });
      }
    }
  }

  // Validate out targets exist
  for (const outName of outputNames) {
    if (!nodes.some((n) => n.id === outName)) {
      throw new DslError(`Output '${outName}' is not defined`, { line: 1, col: 1, offset: 0 });
    }
  }

  const outputs: Record<string, GraphRef> = {};
  for (const name of outputNames) {
    outputs[name] = `${name}.out` as GraphRef;
  }

  // Put inputs first for readability (stable: inputOrder then rest)
  const inputNodes = nodes.filter((n) => n.type === "input");
  const otherNodes = nodes.filter((n) => n.type !== "input");
  // Stable input order
  inputNodes.sort((a, b) => inputOrder.indexOf(a.id) - inputOrder.indexOf(b.id));

  const definition: GraphDefinition = {
    nodes: [...inputNodes, ...otherNodes],
    edges,
    outputs,
  };

  return {
    definition,
    params,
    outputNames,
    inputNames: inputNodes.map((n) => n.id),
  };
}

function wireRef(
  sourceName: string,
  targetNode: string,
  targetPort: string,
  params: Record<string, number>,
  nodeIds: Set<string>,
  ensureInput: (name: string, kind?: PortKind, pos?: DslSourcePosition) => void,
  edges: GraphEdge[],
  pos: DslSourcePosition,
): void {
  if (Object.hasOwn(params, sourceName)) {
    // Params are not edges — they travel as trailing eval args.
    return;
  }
  if (!nodeIds.has(sourceName)) {
    ensureInput(sourceName);
  }
  edges.push({
    from: `${sourceName}.out` as GraphRef,
    to: `${targetNode}.${targetPort}` as GraphRef,
  });
}

// ---------------------------------------------------------------------------
// Equality helper for tests (structural, ignoring node array order)
// ---------------------------------------------------------------------------

/** Normalize a GraphDefinition for structural comparison (sorts nodes/edges). */
export function canonicalizeGraphDefinition(def: GraphDefinition): unknown {
  const nodes = Array.isArray(def.nodes)
    ? def.nodes.map((n) => ({ ...n }))
    : Object.entries(def.nodes).map(([id, n]) => ({ id, ...n }));

  nodes.sort((a, b) => a.id.localeCompare(b.id));

  const edges = Array.isArray(def.edges)
    ? [...(def.edges ?? [])]
    : Object.entries(def.edges ?? {}).map(([from, to]) => ({ from, to }));
  edges.sort((a, b) => `${a.from}->${a.to}`.localeCompare(`${b.from}->${b.to}`));

  const outputs = Array.isArray(def.outputs)
    ? Object.fromEntries(def.outputs.map((n) => [n, `${n}.out`]))
    : { ...(def.outputs ?? {}) };

  // Strip undefined fields for stable JSON
  const cleanNodes = nodes.map((n) => JSON.parse(JSON.stringify(n)));

  return { nodes: cleanNodes, edges, outputs };
}

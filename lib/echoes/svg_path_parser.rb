# frozen_string_literal: true

module Echoes
  # Tokenizer / parser for the `<path d="...">` mini-language.
  # Returns an ordered list of `[cmd_symbol, [args…]]` tuples.
  #
  # Uppercase cmd_symbols (:M, :L, :C, …) are absolute; lowercase
  # (:m, :l, :c, …) are relative — the renderer applies the
  # absolute-vs-relative interpretation since both forms have the
  # same operand counts.
  #
  # Returns nil on:
  #   - empty / nil input
  #   - first command isn't M or m (spec violation; no current point)
  #   - unknown command letter
  #   - operand-count mismatch (e.g. trailing partial group)
  #   - any tokenizer leftover (unrecognized character)
  module SvgPathParser
    # Operand count per command, per spec.
    OPERAND_COUNT = {
      M: 2, m: 2,
      L: 2, l: 2,
      H: 1, h: 1,
      V: 1, v: 1,
      C: 6, c: 6,
      S: 4, s: 4,
      Q: 4, q: 4,
      T: 2, t: 2,
      A: 7, a: 7,
      Z: 0, z: 0,
    }.freeze

    # Implicit continuation: after consuming a command's operands, if
    # there are more numbers without a new command letter, reuse the
    # last command — except M/m, where the implicit continuation is
    # L/l per spec ("Subsequent pairs are treated as implicit lineto
    # commands").
    IMPLICIT_CONTINUATION = {M: :L, m: :l}.freeze

    # Token regex: matches a command letter (excluding E/e which are
    # reserved for scientific-notation exponents) OR a number.
    # Number form: optional sign, then digits-and-optional-decimal or
    # leading-decimal, with optional scientific notation. Whitespace
    # and commas between tokens are silently skipped by the scanner.
    TOKEN_RE = /
      ([MmLlHhVvCcSsQqTtAaZz]) |
      ([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)
    /x

    module_function

    def parse(d)
      return nil if d.nil?
      tokens = tokenize(d)
      return nil if tokens.nil? || tokens.empty?

      # First token must be M or m.
      first = tokens.first
      return nil unless first.is_a?(Symbol) && (first == :M || first == :m)

      ops = []
      i = 0
      last_cmd = nil
      while i < tokens.size
        tok = tokens[i]
        if tok.is_a?(Symbol)
          cmd = tok
          i += 1
        else
          return nil unless last_cmd
          cmd = IMPLICIT_CONTINUATION[last_cmd] || last_cmd
        end

        arity = OPERAND_COUNT[cmd]
        return nil unless arity

        if arity.zero?
          ops << [cmd, []]
          last_cmd = cmd
          next
        end

        args = tokens[i, arity]
        return nil if args.size < arity
        return nil if args.any? { |t| t.is_a?(Symbol) }

        ops << [cmd, args]
        i += arity
        last_cmd = cmd
      end

      ops
    end

    # Scan the string for tokens, ensuring we account for every
    # non-whitespace, non-comma character. If any junk is left,
    # returns nil so the caller can bail.
    def tokenize(d)
      tokens = []
      pos = 0
      bytes = d.b
      while pos < bytes.length
        # Skip separators (whitespace, comma).
        if (m = /\G[\s,]+/.match(bytes, pos))
          pos = m.end(0)
          next
        end
        m = TOKEN_RE.match(bytes, pos)
        return nil unless m && m.begin(0) == pos
        if m[1]
          tokens << m[1].to_sym
        else
          tokens << m[2].to_f
        end
        pos = m.end(0)
      end
      tokens
    end
  end
end

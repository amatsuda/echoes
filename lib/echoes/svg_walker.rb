# frozen_string_literal: true

module Echoes
  # Minimal SVG element scanner. Yields one event per element to
  # the block (or returns an Enumerator):
  #
  #   [:open,        tag, {attr => value, …}]
  #   [:close,       tag, {}]
  #   [:self_close,  tag, {attr => value, …}]
  #
  # Skips comments, processing instructions (`<?xml…?>`), DOCTYPE
  # declarations, and CDATA sections. Text content between tags is
  # ignored (the fast-path SVG renderer doesn't render text — any
  # SVG that uses <text> is rejected before we walk it).
  #
  # Stops yielding on malformed input (no matching `>`, unbalanced
  # comment, etc.). The caller treats early termination as "can't
  # render — bail to WKWebView."
  module SvgWalker
    TAG_NAME_RE = /[a-zA-Z][\w:.-]*/
    # `\G` anchors the match to the scan offset passed to Regexp#match,
    # so we can reuse the same regex from any position. `\A` would
    # only match at string-position 0, which is wrong once we're past
    # the first tag.
    CLOSE_TAG_RE = /\G<\/(#{TAG_NAME_RE})\s*>/m
    OPEN_TAG_RE  = /\G<(#{TAG_NAME_RE})([^>]*)>/m
    ATTR_RE      = /(#{TAG_NAME_RE})\s*=\s*(?:"([^"]*)"|'([^']*)')/

    module_function

    def events(bytes)
      return enum_for(:events, bytes) unless block_given?
      return if bytes.nil?

      s = bytes.b
      pos = 0
      len = s.length
      while pos < len
        lt = s.index('<', pos)
        break unless lt
        pos = lt

        # Comment: <!-- … -->
        if s[pos, 4] == '<!--'
          close = s.index('-->', pos + 4)
          break unless close
          pos = close + 3
          next
        end

        # CDATA: <![CDATA[ … ]]>
        if s[pos, 9] == '<![CDATA['
          close = s.index(']]>', pos + 9)
          break unless close
          pos = close + 3
          next
        end

        # Other declarations: <!DOCTYPE …>, <!ENTITY …>, etc.
        if s[pos, 2] == '<!'
          close = s.index('>', pos + 2)
          break unless close
          pos = close + 1
          next
        end

        # Processing instruction: <?xml …?>
        if s[pos, 2] == '<?'
          close = s.index('?>', pos + 2)
          break unless close
          pos = close + 2
          next
        end

        # Closing tag: </tag>
        if s[pos, 2] == '</'
          m = CLOSE_TAG_RE.match(s, pos)
          break unless m && m.begin(0) == pos
          yield [:close, m[1], {}]
          pos = m.end(0)
          next
        end

        # Opening or self-closing tag.
        m = OPEN_TAG_RE.match(s, pos)
        break unless m && m.begin(0) == pos
        tag = m[1]
        body = m[2]
        if body.rstrip.end_with?('/')
          attrs_str = body.rstrip.chomp('/')
          yield [:self_close, tag, parse_attrs(attrs_str)]
        else
          yield [:open, tag, parse_attrs(body)]
        end
        pos = m.end(0)
      end
    end

    def parse_attrs(str)
      out = {}
      str.scan(ATTR_RE) do |name, dq, sq|
        out[name] = dq || sq || ''
      end
      out
    end
  end
end

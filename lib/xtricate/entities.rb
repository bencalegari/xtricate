module Xtricate
  # HTML entity decoding for scraped/API text.
  #
  # CGI.unescapeHTML only knows &amp; &lt; &gt; &quot; &apos; plus numeric refs,
  # so named entities that newsrooms actually emit in og:title — &lsquo;, &rsquo;,
  # &mdash;, &nbsp;, &hellip; — survive it untouched and then get re-escaped by
  # the renderer, showing up literally as "&lsquo;" in the email. This decodes
  # the named set as well. Zero dependencies (no nokogiri/htmlentities), so the
  # table is curated: punctuation, symbols, and Latin-1 accents — the entities
  # that appear in headlines and article descriptions.
  module Entities
    NAMED = {
      # Core markup
      "amp" => "&", "lt" => "<", "gt" => ">", "quot" => '"',
      "apos" => "'", "nbsp" => " ",

      # Quotes and dashes — the common offenders
      "lsquo" => "‘", "rsquo" => "’", "sbquo" => "‚",
      "ldquo" => "“", "rdquo" => "”", "bdquo" => "„",
      "lsaquo" => "‹", "rsaquo" => "›",
      "laquo" => "«", "raquo" => "»",
      "ndash" => "–", "mdash" => "—", "horbar" => "―",
      "minus" => "−", "shy" => "­",

      # Punctuation and spacing
      "hellip" => "…", "middot" => "·", "bull" => "•",
      "dagger" => "†", "Dagger" => "‡", "prime" => "′",
      "Prime" => "″", "ensp" => " ", "emsp" => " ",
      "thinsp" => " ", "zwnj" => "‌", "zwj" => "‍",
      "iexcl" => "¡", "iquest" => "¿", "para" => "¶",
      "sect" => "§", "lowast" => "∗",

      # Symbols
      "copy" => "©", "reg" => "®", "trade" => "™",
      "deg" => "°", "plusmn" => "±", "times" => "×",
      "divide" => "÷", "frac12" => "½", "frac14" => "¼",
      "frac34" => "¾", "sup1" => "¹", "sup2" => "²",
      "sup3" => "³", "micro" => "µ", "permil" => "‰",
      "ne" => "≠", "le" => "≤", "ge" => "≥",
      "larr" => "←", "rarr" => "→", "uarr" => "↑",
      "darr" => "↓", "harr" => "↔",

      # Currency
      "cent" => "¢", "pound" => "£", "curren" => "¤",
      "yen" => "¥", "euro" => "€",

      # Latin-1 letters (names, place names, loanwords)
      "Agrave" => "À", "Aacute" => "Á", "Acirc" => "Â",
      "Atilde" => "Ã", "Auml" => "Ä", "Aring" => "Å",
      "AElig" => "Æ", "Ccedil" => "Ç", "Egrave" => "È",
      "Eacute" => "É", "Ecirc" => "Ê", "Euml" => "Ë",
      "Igrave" => "Ì", "Iacute" => "Í", "Icirc" => "Î",
      "Iuml" => "Ï", "ETH" => "Ð", "Ntilde" => "Ñ",
      "Ograve" => "Ò", "Oacute" => "Ó", "Ocirc" => "Ô",
      "Otilde" => "Õ", "Ouml" => "Ö", "Oslash" => "Ø",
      "Ugrave" => "Ù", "Uacute" => "Ú", "Ucirc" => "Û",
      "Uuml" => "Ü", "Yacute" => "Ý", "THORN" => "Þ",
      "szlig" => "ß", "agrave" => "à", "aacute" => "á",
      "acirc" => "â", "atilde" => "ã", "auml" => "ä",
      "aring" => "å", "aelig" => "æ", "ccedil" => "ç",
      "egrave" => "è", "eacute" => "é", "ecirc" => "ê",
      "euml" => "ë", "igrave" => "ì", "iacute" => "í",
      "icirc" => "î", "iuml" => "ï", "eth" => "ð",
      "ntilde" => "ñ", "ograve" => "ò", "oacute" => "ó",
      "ocirc" => "ô", "otilde" => "õ", "ouml" => "ö",
      "oslash" => "ø", "ugrave" => "ù", "uacute" => "ú",
      "ucirc" => "û", "uuml" => "ü", "yacute" => "ý",
      "thorn" => "þ", "yuml" => "ÿ",

      # Greek letters that show up in tech/finance copy
      "alpha" => "α", "beta" => "β", "gamma" => "γ",
      "delta" => "δ", "Delta" => "Δ", "pi" => "π",
      "sigma" => "σ", "Sigma" => "Σ", "mu" => "μ",
      "lambda" => "λ", "omega" => "ω", "Omega" => "Ω"
    }.freeze

    PATTERN = /&(?:#(\d{1,7})|#[xX]([0-9a-fA-F]{1,6})|([A-Za-z][A-Za-z0-9]{1,31}));/.freeze

    # Decode one level of entity encoding. Deliberately single-pass: text that
    # arrives double-encoded (&amp;lsquo;) should decode to "&lsquo;", not to a
    # curly quote — decoding twice would let "&amp;lt;script&gt;" become live
    # markup after the renderer's escape pass.
    def self.decode(str)
      s = str.to_s
      return s unless s.include?("&")

      s.gsub(PATTERN) do |whole|
        dec = Regexp.last_match(1)
        hex = Regexp.last_match(2)
        name = Regexp.last_match(3)
        if name
          NAMED.fetch(name, whole)
        else
          char_for(dec ? dec.to_i : hex.to_i(16)) || whole
        end
      end
    end

    # Reject codepoints that aren't valid scalar values (surrogates, out of
    # range, NUL) so a malformed ref can't raise or inject a control char.
    def self.char_for(codepoint)
      return nil if codepoint.zero? || codepoint > 0x10FFFF
      return nil if codepoint.between?(0xD800, 0xDFFF)

      codepoint.chr(Encoding::UTF_8)
    rescue RangeError
      nil
    end
    private_class_method :char_for
  end
end

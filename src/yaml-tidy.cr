require "yaml"

# `YamlTidy` range un fichier YAML : trie les clés des mappings par ordre
# ALPHABÉTIQUE, RÉCURSIVEMENT À TOUS LES NIVEAUX (enfants, petits-enfants…),
# Y COMPRIS les clés À L'INTÉRIEUR d'un item de séquence qui est un mapping
# (ex. `users: - name/groups` → `groups` avant `name`), ET les ÉLÉMENTS des
# séquences en bloc (`- …`), par ordre alphabétique de :
#   - leur texte pour un scalaire (`- zsh`) ;
#   - leur `name:` pour un mapping qui en a un (`- name: admin`) ;
#   - sinon leur première clé (`- netif-ipv6: { … }`), puis la ligne entière.
# Les séquences EN LIGNE (`[a, b]`) restent telles quelles (l'ordre y est
# souvent un sens : une paire `[active, suivante]`). PRÉSERVE :
#   - les commentaires AU-DESSUS d'une clé ou d'un élément (déplacés avec lui) ;
#   - les commentaires INLINE.
# Optionnellement, épingle une 1ʳᵉ ligne de commentaire (`header`), idempotent.
#
# Approche ligne-à-ligne : le `YAML` de la stdlib perd les commentaires, alors
# qu'ils portent souvent l'essentiel de l'info pour un humain. Hypothèse :
# indentation par espaces. Les scalaires MULTI-LIGNES (blocs `|`/`>` et
# chaînes entre apostrophes ou guillemets sur plusieurs lignes) sont recopiés
# TELS QUELS : leurs lignes sont du texte, jamais des clés à trier.
#
#     YamlTidy.tidy(File.read("conf.yml"))                 # tri seul
#     YamlTidy.tidy(content, header: "monserveur.example") # + `# monserveur.example` en tête
module YamlTidy
  extend self

  # Levée si le résultat ne porte plus les mêmes données que l'entrée (à l'ordre
  # des listes en bloc près) : un défaut d'analyse ne doit JAMAIS produire un
  # fichier altéré — mieux vaut refuser.
  class Error < Exception
  end

  VERSION = {{
              (read_file("#{__DIR__}/../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Un nœud, selon le cas :
  #   - mapping ou scalaire : `line` = ligne brute, `children` = sous-clés ;
  #   - ÉLÉMENT de séquence qui est un mapping (« dash-map ») : `dash_indent`
  #     = indentation du tiret, `children` = ses entrées (mapping à trier) ;
  #   - commentaires seuls (fin de bloc) : `line` nil, pas de `dash_indent`.
  class Node
    property comments : Array(String)
    property line : String?
    property key : String?
    property children : Array(Node)
    property dash_indent : Int32?
    # Lignes d'un scalaire multi-ligne qui suit `line` : recopiées telles quelles.
    property raw : Array(String)

    def initialize(@comments : Array(String), @line : String?, @key : String?)
      @children = [] of Node
      @dash_indent = nil
      @raw = [] of String
    end

    # Élément de séquence (scalaire `- foo` ou dash-map) → ordre préservé.
    def seq_element? : Bool
      !dash_indent.nil? || !!line.try(&.lstrip.starts_with?("- "))
    end
  end

  def tidy(content : String, header : String? = nil) : String
    lines = content.split('\n')
    lines.pop if lines.last? == "" # newline final
    body_start = header_end(lines)
    comments = lines[0...body_start].select { |l| l.lstrip.starts_with?('#') }
    nodes, _ = parse(lines, body_start, 0)
    sort!(nodes)
    result = String.build do |io|
      emit_header(io, comments, header)
      emit(io, nodes, top: true)
    end
    check!(content, result)
    result
  end

  # Données identiques à l'ordre des listes près, sinon `Error`. Une entrée
  # que YAML ne sait pas lire n'est pas vérifiable : rendue telle quelle.
  private def check!(before : String, after : String) : Nil
    a = begin
      YAML.parse(before)
    rescue YAML::ParseException
      return
    end
    b = YAML.parse(after) rescue raise Error.new("résultat illisible en YAML")
    raise Error.new("le rangement changerait les données") unless unordered(a) == unordered(b)
  end

  # Données à l'ordre près : clés de mapping et éléments de liste triés.
  private def unordered(node : YAML::Any) : YAML::Any
    if h = node.as_h?
      YAML::Any.new(h.to_a.sort_by(&.[0].to_s).to_h.transform_values { |v| unordered(v) })
    elsif arr = node.as_a?
      YAML::Any.new(arr.map { |v| unordered(v) }.sort_by(&.to_yaml))
    else
      node
    end
  end

  private def emit(io : IO, nodes : Array(Node), top : Bool = false) : Nil
    nodes.each_with_index do |n, i|
      io << '\n' if top && i > 0 # ligne vide entre blocs top-level
      n.comments.each { |c| io << c << '\n' }
      if di = n.dash_indent
        emit_dash_map(io, n, di)
      elsif l = n.line
        io << l << '\n'
        n.raw.each { |r| io << r << '\n' }
        emit(io, n.children)
      end
    end
  end

  # Émet un élément de séquence mapping : 1ʳᵉ clé (triée) sur la ligne du
  # tiret, les suivantes alignées à `dash_indent + 2`.
  private def emit_dash_map(io : IO, node : Node, dash_indent : Int32) : Nil
    node.children.each_with_index do |e, i|
      e.comments.each { |c| io << c << '\n' }
      line = e.line || ""
      if i == 0
        io << " " * dash_indent << "- " << line.lstrip << '\n'
      else
        io << line << '\n'
      end
      e.raw.each { |r| io << r << '\n' }
      emit(io, e.children)
    end
  end

  # En-tête de commentaires : épingle `# <header>` en 1ʳᵉ ligne si fourni
  # (idempotent — pas de doublon), puis les commentaires d'en-tête existants.
  private def emit_header(io : IO, comments : Array(String), header : String?) : Nil
    if header
      pin = "# #{header}"
      io << pin << '\n'
      comments.reject { |l| l.strip == pin }.each { |l| io << l << '\n' }
      io << '\n'
    elsif !comments.empty?
      comments.each { |l| io << l << '\n' }
      io << '\n'
    end
  end

  # Indice de la 1ʳᵉ ligne de CONTENU (ni commentaire ni vide) en tête.
  private def header_end(lines : Array(String)) : Int32
    i = 0
    while i < lines.size
      s = lines[i].strip
      break unless s.empty? || s.starts_with?('#')
      i += 1
    end
    i
  end

  private def indent_of(line : String) : Int32
    line.size - line.lstrip.size
  end

  # Clé d'une ligne `key: …` (pour le tri), SANS ses guillemets : `"netif-ipv6":`
  # se trie comme `netif-ipv6:`, et un `:` entre guillemets (`- "a: b"`) n'en
  # fait pas une clé. nil si pas une clé de mapping.
  private def key_of(stripped : String) : String?
    if (q = stripped[0]?) && (q == '"' || q == '\'')
      close = stripped.index(q, 1)
      return unless close && stripped[(close + 1)..].lstrip.starts_with?(':')
      return stripped[1...close]
    end
    i = stripped.index(':')
    i ? stripped[0...i].strip : nil
  end

  # Genre de scalaire multi-ligne OUVERT par la ligne : `:block` (valeur `|`
  # ou `>`, indicateurs `-`/`+`/chiffre, commentaire possible), `'\''` ou `'"'`
  # (chaîne entre apostrophes/guillemets non refermée sur la ligne) ; nil sinon.
  def multiline_scalar_kind(stripped : String) : Symbol | Char?
    value = if stripped.starts_with?("- ") && !key_of(stripped[2..])
              stripped[2..]
            elsif i = stripped.index(": ")
              stripped[(i + 2)..]
            else
              return
            end
    value = value.strip
    return :block if value.matches?(/\A[|>][-+0-9]*\s*(#.*)?\z/)
    return if value.empty?
    q = value[0]
    return unless q == '\'' || q == '"'
    closes?(value[1..], q) ? nil : q
  end

  def multiline_scalar_start?(stripped : String) : Bool
    !multiline_scalar_kind(stripped).nil?
  end

  # Vrai si `text` contient le guillemet FERMANT `q` (hors échappements :
  # `''` entre apostrophes, `\"` et `\\` entre guillemets).
  private def closes?(text : String, q : Char) : Bool
    if q == '\''
      text.gsub("''", "").includes?('\'')
    else
      text.gsub("\\\\", "").gsub("\\\"", "").includes?('"')
    end
  end

  # Lignes d'une chaîne entre guillemets sur plusieurs lignes : jusqu'à la
  # ligne qui la referme, QUELLE QUE SOIT son indentation (le `to_yaml` de
  # Crystal pose l'apostrophe fermante en colonne 0). Retourne {lignes, idx}.
  private def slurp_quoted(lines : Array(String), idx : Int32, q : Char) : Tuple(Array(String), Int32)
    raw = [] of String
    while idx < lines.size
      raw << lines[idx]
      idx += 1
      break if closes?(raw.last, q)
    end
    {raw, idx}
  end

  # Lignes d'un scalaire multi-ligne : tout ce qui est plus indenté que la
  # ligne d'ouverture (`indent`), lignes vides intérieures comprises ; les
  # lignes vides finales ne font pas partie du scalaire. Retourne {lignes, idx}.
  private def slurp_scalar(lines : Array(String), idx : Int32, indent : Int32) : Tuple(Array(String), Int32)
    raw = [] of String
    while idx < lines.size && (lines[idx].strip.empty? || indent_of(lines[idx]) > indent)
      raw << lines[idx]
      idx += 1
    end
    while raw.last?.try(&.strip.empty?)
      raw.pop
      idx -= 1
    end
    {raw, idx}
  end

  private def next_indent(lines : Array(String), idx : Int32) : Int32?
    while idx < lines.size
      return indent_of(lines[idx]) unless lines[idx].strip.empty?
      idx += 1
    end
    nil
  end

  # Parse tous les nœuds AU niveau `indent`, avec leurs enfants (indentation
  # > `indent`). Retourne {nœuds, idx-suivant}.
  private def parse(lines : Array(String), idx : Int32, indent : Int32) : Tuple(Array(Node), Int32)
    nodes = [] of Node
    comments = [] of String
    comment_start = idx
    while idx < lines.size
      line = lines[idx]
      if line.strip.empty?
        idx += 1
        next
      end
      if line.lstrip.starts_with?('#')
        comment_start = idx if comments.empty?
        comments << line
        idx += 1
        next
      end
      ci = indent_of(line)
      if ci < indent
        unless comments.empty?
          idx = comment_start # rendre les commentaires au parent (rewind)…
          comments.clear      # …et NE PAS les ré-émettre ici (sinon doublon)
        end
        break
      end
      break if ci > indent # défensif

      stripped = line.lstrip
      if kind = multiline_scalar_kind(stripped)
        # Scalaire multi-ligne (`notes: |`, `- >`, `x: 'début…`) : ses lignes
        # sont du TEXTE → recopiées telles quelles, jamais triées.
        node = Node.new(comments.dup, line, stripped.starts_with?("- ") ? nil : key_of(stripped))
        node.raw, idx = kind.is_a?(Char) ? slurp_quoted(lines, idx + 1, kind) : slurp_scalar(lines, idx + 1, ci)
      elsif stripped.starts_with?("- ") && (rest = stripped[2..]) && key_of(rest)
        # ÉLÉMENT de séquence qui est un mapping (« dash-map ») : on reconstruit
        # son mapping = entrée inline (après `- `) + lignes de continuation
        # (indentées à `indent + 2`), puis on parse/trie ce mapping.
        entry_indent = indent + 2
        idx += 1
        cont = [] of String
        while idx < lines.size && (lines[idx].strip.empty? || indent_of(lines[idx]) >= entry_indent)
          cont << lines[idx]
          idx += 1
        end
        synth = [" " * entry_indent + rest] + cont
        entries, _ = parse(synth, 0, entry_indent)
        node = Node.new(comments.dup, nil, nil)
        node.dash_indent = indent
        node.children = entries
      else
        # mapping classique OU élément de séquence SCALAIRE (`- foo`).
        node = Node.new(comments.dup, line, stripped.starts_with?("- ") ? nil : key_of(stripped))
        idx += 1
        if (nxt = next_indent(lines, idx)) && nxt > indent
          node.children, idx = parse(lines, idx, nxt)
        elsif nxt == indent && node.key && stripped.rstrip.ends_with?(':') && dash_line_next?(lines, idx)
          # Séquence AU MÊME niveau que sa clé (`disks:` puis `- /dev/sda`, YAML
          # valide) : ses éléments sont les ENFANTS de la clé, pas des voisins.
          run, idx = dash_run(lines, idx, indent)
          node.children, _ = parse(run, 0, indent)
        end
      end
      comments.clear
      nodes << node
    end
    nodes << Node.new(comments.dup, nil, nil) unless comments.empty? # commentaires de fin
    {nodes, idx}
  end

  # La prochaine ligne de contenu (hors vides et commentaires) est-elle un `- …` ?
  private def dash_line_next?(lines : Array(String), idx : Int32) : Bool
    while idx < lines.size
      s = lines[idx].strip
      return s.starts_with?("- ") || s == "-" unless s.empty? || s.starts_with?('#')
      idx += 1
    end
    false
  end

  # Lignes d'une séquence écrite au niveau `indent` de sa clé : ses `- …`, leurs
  # lignes plus indentées, et les vides/commentaires qui précèdent un `- …`.
  # S'arrête à la 1ʳᵉ ligne de contenu de niveau `indent` qui n'est pas un `- `.
  private def dash_run(lines : Array(String), idx : Int32, indent : Int32) : Tuple(Array(String), Int32)
    run = [] of String
    while idx < lines.size
      line = lines[idx]
      s = line.strip
      if s.empty? || s.starts_with?('#')
        break unless dash_line_next?(lines, idx)
      elsif indent_of(line) == indent && !s.starts_with?("- ")
        break
      elsif indent_of(line) < indent
        break
      end
      run << line
      idx += 1
    end
    {run, idx}
  end

  # Tri récursif. Niveau de SÉQUENCE → éléments triés (`element_key`, ordre
  # d'origine à égalité), après avoir trié DANS chaque élément (dash-map) ;
  # les commentaires de fin restent à la fin. Niveau de MAPPING → trié par
  # clé, puis récursion.
  private def sort!(nodes : Array(Node)) : Nil
    if nodes.any?(&.seq_element?)
      nodes.each { |n| sort!(n.children) }
      elements, tail = nodes.partition(&.seq_element?)
      sorted = elements.each_with_index.to_a.sort_by! { |(n, i)| {element_key(n), i} }.map(&.first)
      nodes.replace(sorted + tail)
      return
    end
    nodes.sort_by! { |n| n.line.nil? ? "￿￿" : (n.key || "￿") }
    nodes.each { |n| sort!(n.children) }
  end

  # Clé de tri d'un élément de séquence : texte d'un scalaire (`- zsh` → `zsh`),
  # `name:` d'un mapping qui en a un, sinon sa première clé puis sa ligne.
  private def element_key(node : Node) : Tuple(String, String)
    if node.dash_indent
      entries = node.children.select(&.line)
      if named = entries.find { |e| e.key == "name" }
        return {scalar_text(named.line.not_nil!.lstrip[5..]), ""}
      end
      first = entries.min_by? { |e| e.key || "" }
      return {first.try(&.key) || "", first.try(&.line).try(&.strip) || ""}
    end
    text = (node.line || "").lstrip
    text = text[2..] if text.starts_with?("- ")
    {scalar_text(text), ""}
  end

  # Scalaire sans guillemets ni espaces autour (`"zsh"` → `zsh`).
  private def scalar_text(text : String) : String
    t = text.strip
    t.size >= 2 && (t[0] == '"' || t[0] == '\'') && t[-1] == t[0] ? t[1...-1] : t
  end
end

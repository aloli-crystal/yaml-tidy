# `YamlTidy` range un fichier YAML : trie les clés des mappings par ordre
# ALPHABÉTIQUE, RÉCURSIVEMENT À TOUS LES NIVEAUX (enfants, petits-enfants…),
# Y COMPRIS les clés À L'INTÉRIEUR d'un item de séquence qui est un mapping
# (ex. `users: - name/groups` → `groups` avant `name`). PRÉSERVE :
#   - les commentaires AU-DESSUS d'une clé (déplacés avec elle au tri) ;
#   - les commentaires INLINE ;
#   - l'ORDRE des ÉLÉMENTS de séquence — seules les CLÉS sont triées.
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
    String.build do |io|
      emit_header(io, comments, header)
      emit(io, nodes, top: true)
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

  # Clé d'une ligne `key: …` (pour le tri). nil si pas une clé de mapping.
  private def key_of(stripped : String) : String?
    i = stripped.index(':')
    i ? stripped[0...i].strip : nil
  end

  # Genre de scalaire multi-ligne OUVERT par la ligne : `:block` (valeur `|`
  # ou `>`, indicateurs `-`/`+`/chiffre, commentaire possible), `'\''` ou `'"'`
  # (chaîne entre apostrophes/guillemets non refermée sur la ligne) ; nil sinon.
  def multiline_scalar_kind(stripped : String) : Symbol | Char | Nil
    value = if stripped.starts_with?("- ") && !key_of(stripped[2..])
              stripped[2..]
            elsif i = stripped.index(": ")
              stripped[(i + 2)..]
            else
              return nil
            end
    value = value.strip
    return :block if value.matches?(/\A[|>][-+0-9]*\s*(#.*)?\z/)
    return nil if value.empty?
    q = value[0]
    return nil unless q == '\'' || q == '"'
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
        end
      end
      comments.clear
      nodes << node
    end
    nodes << Node.new(comments.dup, nil, nil) unless comments.empty? # commentaires de fin
    {nodes, idx}
  end

  # Tri récursif. Niveau de SÉQUENCE → ordre des éléments PRÉSERVÉ, mais on
  # descend trier DANS chaque élément (dash-map). Niveau de MAPPING → trié
  # par clé, puis récursion.
  private def sort!(nodes : Array(Node)) : Nil
    if nodes.any?(&.seq_element?)
      nodes.each { |n| sort!(n.children) }
      return
    end
    nodes.sort_by! { |n| n.line.nil? ? "￿￿" : (n.key || "￿") }
    nodes.each { |n| sort!(n.children) }
  end
end

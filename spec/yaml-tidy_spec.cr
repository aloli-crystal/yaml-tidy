require "./spec_helper"

# Données YAML à l'ordre des listes près (les éléments sont désormais triés).
private def unordered(node : YAML::Any) : YAML::Any
  if h = node.as_h?
    YAML::Any.new(h.to_a.sort_by(&.[0].to_s).to_h.transform_values { |v| unordered(v) })
  elsif a = node.as_a?
    YAML::Any.new(a.map { |v| unordered(v) }.sort_by(&.to_yaml))
  else
    node
  end
end

SAMPLE = <<-YAML
  # Mis à jour par beryl scan
  # vos clés préservées
  provider: ovh
  ovh:
    service_name: ns1.eu
    commercial_name: RISE-1 | Xeon
  vrack:
    name: pn-1
    # IP primaire du vRack
    ip: 192.168.42.31
    proxy_jump: admin@zsbg.quimeo.net # via bastion
  freebsd:
    hostname: ben
    zfs:
      zroot:
        raid: 0
        boot: true
        disks:
          - /dev/sda
          - /dev/sdb
  apply_recipes:
    - oh-my-zsh: { user: deploy }
    - clamav
  YAML

describe YamlTidy do
  it "épingle l'en-tête fourni en première ligne (idempotent)" do
    res = YamlTidy.tidy(SAMPLE, header: "ben.quimeo.net")
    res.lines.first.should eq("# ben.quimeo.net")
    res.should contain("# Mis à jour par beryl scan") # en-tête existant conservé
    twice = YamlTidy.tidy(res, header: "ben.quimeo.net")
    twice.scan("# ben.quimeo.net").size.should eq(1)
    twice.should eq(res)
  end

  it "sans header : ne pose pas de 1ʳᵉ ligne, garde les commentaires d'en-tête" do
    res = YamlTidy.tidy(SAMPLE)
    res.lines.first.should eq("# Mis à jour par beryl scan")
  end

  it "trie les clés top-level et imbriquées par ordre alpha" do
    res = YamlTidy.tidy(SAMPLE)
    %w[apply_recipes: freebsd: ovh: provider: vrack:].each_cons(2) do |(a, b)|
      res.index(a).not_nil!.should be < res.index(b).not_nil!
    end
    res.index("commercial_name").not_nil!.should be < res.index("service_name").not_nil!
    res.index("boot:").not_nil!.should be < res.index("disks:").not_nil!
    res.index("disks:").not_nil!.should be < res.index("raid:").not_nil!
  end

  it "trie les ÉLÉMENTS des séquences en bloc (recettes, disques)" do
    res = YamlTidy.tidy(SAMPLE)
    res.index("clamav").not_nil!.should be < res.index("oh-my-zsh").not_nil!
    res.index("/dev/sda").not_nil!.should be < res.index("/dev/sdb").not_nil!
  end

  it "trie un mapping d'élément par son `name:`, et un mélange scalaires / mappings par clé" do
    yaml = "apply_recipes:\n  - zfs-scrub\n  - netif-ipv6: { gateway: \"fe80::1\" }\n  - acme\n"
    YamlTidy.tidy(yaml).should eq("apply_recipes:\n  - acme\n  - netif-ipv6: { gateway: \"fe80::1\" }\n  - zfs-scrub\n")
  end

  it "garde une séquence écrite au niveau de sa clé sous cette clé (`disks:` puis `- …`)" do
    yaml = "zroot:\n  raid: 0\n  disks:\n  - /dev/sdb\n  - /dev/sda\n  boot: true\n"
    res = YamlTidy.tidy(yaml)
    res.should eq("zroot:\n  boot: true\n  disks:\n  - /dev/sda\n  - /dev/sdb\n  raid: 0\n")
    unordered(YAML.parse(res)).should eq(unordered(YAML.parse(yaml)))
  end

  it "trie une clé entre guillemets comme sans guillemets (mapping et élément de liste)" do
    YamlTidy.tidy(%(zeta: 1\n"beta": 2\nalpha: 3\n)).should eq(%(alpha: 3\n\n"beta": 2\n\nzeta: 1\n))
    yaml = %(apply_recipes:\n  - partiduo-store\n  - "netif-ipv6": { gateway: "fe80::1" }\n  - acme\n)
    YamlTidy.tidy(yaml).should eq(%(apply_recipes:\n  - acme\n  - "netif-ipv6": { gateway: "fe80::1" }\n  - partiduo-store\n))
  end

  it "ne prend pas un « : » entre guillemets pour une clé (élément scalaire)" do
    yaml = %(notes:\n  - "z: dernier"\n  - "a: premier"\n)
    YamlTidy.tidy(yaml).should eq(%(notes:\n  - "a: premier"\n  - "z: dernier"\n))
  end

  it "laisse les séquences EN LIGNE telles quelles (paire [active, suivante])" do
    yaml = "ssh_keys:\n  - [zeta.pub, alpha.pub]\n"
    YamlTidy.tidy(yaml).should eq(yaml)
  end

  it "déplace le commentaire d'un élément avec lui, et garde le commentaire de fin à la fin" do
    yaml = "packages:\n  # shell\n  - zsh\n  - curl\n  # fin de liste\n"
    YamlTidy.tidy(yaml).should eq("packages:\n  - curl\n  # shell\n  - zsh\n  # fin de liste\n")
  end

  it "préserve les commentaires au-dessus d'une clé ET inline" do
    res = YamlTidy.tidy(SAMPLE)
    res.should contain("# IP primaire du vRack")
    res.should contain("proxy_jump: admin@zsbg.quimeo.net # via bastion")
    res.should match(/# IP primaire du vRack\n\s+ip: 192\.168\.42\.31/)
  end

  it "ne PERD ni n'altère AUCUNE donnée (parse YAML identique, à l'ordre des listes près)" do
    res = YamlTidy.tidy(SAMPLE, header: "ben.quimeo.net")
    unordered(YAML.parse(res)).should eq(unordered(YAML.parse(SAMPLE)))
  end

  it "ne DUPLIQUE pas un commentaire situé après un bloc imbriqué" do
    yaml = "ovh:\n  service_name: ns1\n# commentaire de vrack\nvrack:\n  ip: 1.2.3.4\n"
    res = YamlTidy.tidy(yaml)
    res.scan("# commentaire de vrack").size.should eq(1)
    res.should match(/# commentaire de vrack\nvrack:/)
  end

  it "trie les clés DANS un item de séquence (dash-map), et les items par `name:`" do
    yaml = "provider: ovh\nusers:\n  - name: deploy\n    groups: [www, wheel]\n  - name: admin\n    groups: [wheel]\n"
    res = YamlTidy.tidy(yaml)
    res.should contain("- groups: [www, wheel]\n    name: deploy")
    res.should contain("- groups: [wheel]\n    name: admin")
    res.index("admin").not_nil!.should be < res.index("deploy").not_nil!
    unordered(YAML.parse(res)).should eq(unordered(YAML.parse(yaml)))
  end

  describe "scalaires multi-lignes (texte recopié tel quel)" do
    it "bloc `|` : ne trie pas les lignes qui contiennent « : »" do
      yaml = "role: apps\nnotes: |\n  Applications marteen.\n  CPU Ivy Bridge : générique.\n  Disque : 160 Go.\n"
      res = YamlTidy.tidy(yaml)
      res.should contain("notes: |\n  Applications marteen.\n  CPU Ivy Bridge : générique.\n  Disque : 160 Go.\n")
      res.index("notes:").not_nil!.should be < res.index("role:").not_nil! # clés triées quand même
      YAML.parse(res).should eq(YAML.parse(yaml))
    end

    it "bloc `>-` avec ligne vide intérieure et commentaire d'indicateur" do
      yaml = "b: 1\na: >- # replié\n  zèbre : un\n\n  alpha : deux\nc: 3\n"
      res = YamlTidy.tidy(yaml)
      res.should contain("a: >- # replié\n  zèbre : un\n\n  alpha : deux\n")
      YAML.parse(res).should eq(YAML.parse(yaml))
    end

    it "chaîne entre apostrophes sur plusieurs lignes (forme écrite par to_yaml)" do
      yaml = "role: backup\nnotes: '16 Go : pas d’applications.\n\n  Cible : sauvegardes.\n\n  '\n"
      res = YamlTidy.tidy(yaml)
      YAML.parse(res)["notes"].should eq(YAML.parse(yaml)["notes"])
      res.should contain("notes: '16 Go : pas d’applications.\n\n  Cible : sauvegardes.\n\n  '\n")
    end

    it "apostrophe fermante en colonne 0 (forme du to_yaml de Crystal)" do
      yaml = "role: backup\nnotes: '16 Go : pas d’applications.\n\n  Cible : sauvegardes.\n\n'\novh:\n  rack: W16\n"
      res = YamlTidy.tidy(yaml)
      res.should contain("notes: '16 Go : pas d’applications.\n\n  Cible : sauvegardes.\n\n'\n")
      YAML.parse(res).should eq(YAML.parse(yaml))
      res.index("notes:").not_nil!.should be < res.index("ovh:").not_nil!
      res.index("ovh:").not_nil!.should be < res.index("role:").not_nil!
    end

    it "bloc dans un item de séquence" do
      yaml = "users:\n  - name: deploy\n    bio: |\n      Zèbre : premier.\n      Alpha : second.\n"
      res = YamlTidy.tidy(yaml)
      res.should contain("  - bio: |\n      Zèbre : premier.\n      Alpha : second.\n    name: deploy\n")
      YAML.parse(res).should eq(YAML.parse(yaml))
    end

    it "idempotent" do
      yaml = "notes: |\n  Zèbre : un.\n  Alpha : deux.\nrole: x\n"
      once = YamlTidy.tidy(yaml)
      YamlTidy.tidy(once).should eq(once)
    end
  end
end

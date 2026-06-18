require "./spec_helper"

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

  it "préserve l'ORDRE des séquences (recettes, disques)" do
    res = YamlTidy.tidy(SAMPLE)
    res.index("oh-my-zsh").not_nil!.should be < res.index("clamav").not_nil!
    res.index("/dev/sda").not_nil!.should be < res.index("/dev/sdb").not_nil!
  end

  it "préserve les commentaires au-dessus d'une clé ET inline" do
    res = YamlTidy.tidy(SAMPLE)
    res.should contain("# IP primaire du vRack")
    res.should contain("proxy_jump: admin@zsbg.quimeo.net # via bastion")
    res.should match(/# IP primaire du vRack\n\s+ip: 192\.168\.42\.31/)
  end

  it "ne PERD ni n'altère AUCUNE donnée (parse YAML identique)" do
    res = YamlTidy.tidy(SAMPLE, header: "ben.quimeo.net")
    YAML.parse(res).should eq(YAML.parse(SAMPLE))
  end

  it "ne DUPLIQUE pas un commentaire situé après un bloc imbriqué" do
    yaml = "ovh:\n  service_name: ns1\n# commentaire de vrack\nvrack:\n  ip: 1.2.3.4\n"
    res = YamlTidy.tidy(yaml)
    res.scan("# commentaire de vrack").size.should eq(1)
    res.should match(/# commentaire de vrack\nvrack:/)
  end

  it "trie les clés DANS un item de séquence (dash-map) sans réordonner la liste" do
    yaml = "provider: ovh\nusers:\n  - name: deploy\n    groups: [www, wheel]\n  - name: admin\n    groups: [wheel]\n"
    res = YamlTidy.tidy(yaml)
    res.should contain("- groups: [www, wheel]\n    name: deploy")
    res.should contain("- groups: [wheel]\n    name: admin")
    res.index("deploy").not_nil!.should be < res.index("admin").not_nil!
    YAML.parse(res).should eq(YAML.parse(yaml))
  end
end

require "./spec_helper"

describe YamlTidy do
  it "VERSION matche shard.yml (lue au compile-time, pas de désynchro possible)" do
    yml = YAML.parse(File.read(File.join(__DIR__, "..", "shard.yml")))
    YamlTidy::VERSION.should eq(yml["version"].as_s)
  end

  it "VERSION est au format SemVer X.Y.Z" do
    YamlTidy::VERSION.should match(/^\d+\.\d+\.\d+(\.\d+)?$/)
  end
end

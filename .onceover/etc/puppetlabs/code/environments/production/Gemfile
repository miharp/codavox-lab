source 'https://rubygems.org'

# Control-repo-wide testing. Onceover compiles every role against representative
# node factsets, so a role that cannot compile is caught before a VM is built.
#
# It cannot catch everything: compiling a role proves the role is valid, not that
# any node is classified into it. That gap cost a whole afternoon in the dev
# control repo, where role::compiler compiled cleanly in onceover and had never
# run on a node. spec/onceover.yaml and manifests/site.pp have to agree, and only
# a real agent run proves they do.
#
#   bundle install
#   bundle exec onceover run spec
group :test do
  # openvox, not puppet: this is an OpenVox estate, and the gems diverge.
  gem 'openvox', ENV.fetch('PUPPET_GEM_VERSION', '~> 8.0'), require: false

  gem 'onceover', '~> 5.0', require: false
end

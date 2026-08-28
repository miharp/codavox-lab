forge 'https://forge.puppet.com'

# Kept deliberately small. This control repo exists to validate codavox, so every
# module here is one codavox itself needs or that the lab uses to prove a catalog
# compiled and applied.
mod 'puppetlabs/stdlib',       '9.7.0'
mod 'puppetlabs/inifile',      '6.4.1'
# yumrepo left Puppet core. Real nodes get it bundled with openvox-agent, but a
# compile-only environment has to declare it or every RedHat catalog fails with
# "Unknown resource type: 'yumrepo'".
mod 'puppetlabs/yumrepo_core', '3.0.1'

# Not on the Forge yet, so pinned by tag rather than floating on a branch:
# codavox exists to make code versions deterministic, and resolving its own
# module non-deterministically would undercut the point.
mod 'codavox',
  git: 'https://github.com/miharp/puppet-codavox.git',
  tag: 'v0.4.0'

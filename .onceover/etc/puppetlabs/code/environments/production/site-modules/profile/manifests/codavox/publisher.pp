# @summary Seals what r10k deployed and serves it to compilers.
#
# Belongs on the node where r10k runs, because the publisher reads r10k's output
# directory locally. It seals each environment into a content-addressed `code_id`
# and serves the result over mutual TLS, reusing the Puppet CA material already on
# the node — there is no second PKI to provision.
#
# `codavox::basedir` is r10k's `basedir`, which the OpenVox getting-started guide
# sets to /etc/puppetlabs/code/environments. codavox only reads it: it writes
# nothing there and keeps no copy, so it adds no code directory to this node.
#
# The publisher's port is opened by Vagrant provisioning with `firewall-cmd`, not
# managed here. puppetlabs/firewall cannot persist rules on EL9 or EL10 without
# iptables-services, since both default to firewalld — and a lab validating codavox
# should not spend its failures on firewall plumbing. Compilers dial in and nothing
# connects out to them, so 8150 inbound on this node is the only rule the estate
# needs.
class profile::codavox::publisher {
  include codavox
  include codavox::publish
}

# @summary Seals what r10k deployed, serves it, and compiles from it.
#
# Belongs on the node where r10k runs, because the publisher reads r10k's output
# directory locally. It seals each environment into a content-addressed `code_id`
# and serves the result over mutual TLS, reusing the Puppet CA material already on
# the node — there is no second PKI to provision.
#
# `codavox::basedir` is r10k's `basedir`, which the OpenVox getting-started guide
# sets to /etc/puppetlabs/code/environments. codavox only reads it: it writes
# nothing there and keeps no copy.
#
# ## Why the primary is a client of itself
#
# This node compiles at least one catalog — its own — so it wants versioned code
# for the same reason a compiler does. Leaving it publisher-only would make it the
# one machine in the estate serving code no `code_id` describes, which is the
# guarantee the rest of the lab exists to demonstrate.
#
# `codavox::primary` therefore runs the publisher, an agent pointed at that
# publisher, and the server wiring. It is not a single-node mode: the same class
# is what a primary uses whether or not compilers exist, and compiler01 and
# compiler02 change nothing about it.
#
# ## The two-run cutover, on purpose
#
# `codavox::server` repoints `environmentpath` at a directory the agent fills, and
# this node cannot survive that happening early: the agent that would repair it
# needs a catalog from the server it just broke.
#
# So `codavox::primary` reads the `codavox_environments` fact and leaves OpenVox
# Server alone until production has converged. The first run installs codavox and
# starts the publisher and agent; a later run, once the agent has pulled
# something, does the wiring. Vagrant provisioning runs the agent twice for
# exactly that reason, and the lab is where the sequence should be exercised
# rather than discovered.
#
# The publisher's port is opened by Vagrant provisioning with `firewall-cmd`, not
# managed here. puppetlabs/firewall cannot persist rules on EL9 or EL10 without
# iptables-services, since both default to firewalld — and a lab validating codavox
# should not spend its failures on firewall plumbing. Compilers dial in and nothing
# connects out to them, so 8150 inbound on this node is the only rule the estate
# needs.
#
# @example
#   include profile::codavox::primary
class profile::codavox::primary {
  include codavox
  include codavox::primary
}

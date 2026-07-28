# @summary The primary: CA, r10k, the codavox publisher, and its own agent.
#
# It serves no agents other than itself. Every agent in the lab points at a
# compiler, which is how a real multi-compiler estate is laid out and what keeps
# static catalogs purely a codavox property — there are no hand-written code_id
# scripts anywhere in this repo, and no node where a wrong code_id could be
# produced.
#
# It does compile one catalog, though: its own. That is why it runs codavox in
# full rather than publisher-only. A primary that seals code for everyone else
# while compiling its own catalog from an unversioned tree would be the single
# node in the estate without the guarantee, and the lab would be demonstrating
# less than it claims.
#
# r10k deploys into /etc/puppetlabs/code/environments, per the OpenVox
# getting-started guide, and the publisher seals exactly that. Once its own agent
# has converged, this node compiles from the unpacked version directory instead —
# see profile::codavox::primary for why that takes two runs.
#
# @example
#   include role::primary
class role::primary {
  include profile::base
  include profile::openvox_server
  include profile::codavox::primary
}

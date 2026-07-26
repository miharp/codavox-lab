# @summary The primary: CA, r10k, and the codavox publisher.
#
# It deliberately serves no agents. Every agent in the lab points at a compiler,
# which is both how a real multi-compiler estate is laid out and what keeps static
# catalogs purely a codavox property — there are no hand-written code_id scripts
# anywhere in this repo, and no node where a wrong code_id could be produced.
#
# r10k deploys into /etc/puppetlabs/code/environments, per the OpenVox
# getting-started guide, and the publisher seals exactly that.
#
# @example
#   include role::primary
class role::primary {
  include profile::base
  include profile::openvox_server
  include profile::codavox::publisher
}

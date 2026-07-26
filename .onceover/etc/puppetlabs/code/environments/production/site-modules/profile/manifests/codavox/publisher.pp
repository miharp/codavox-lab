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
# @param port
#   The port the publisher listens on, for the firewall rule. Must agree with
#   `codavox::publish_listen`, which is what codavox actually reads.
class profile::codavox::publisher (
  Stdlib::Port $port = 8150,
) {
  include codavox
  include codavox::publish

  # Compilers dial in; nothing connects out to them. This is the only inbound rule
  # codavox needs anywhere in the estate.
  firewall { '100 allow codavox publisher':
    dport => $port,
    proto => 'tcp',
    jump  => 'ACCEPT',
  }
}

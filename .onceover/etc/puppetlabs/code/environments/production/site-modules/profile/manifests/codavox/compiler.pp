# @summary Pulls versioned code onto a compiler and serves catalogs from it.
#
# The agent polls the publisher, verifies each artifact against its `code_id`, and
# swaps the environment symlink atomically. Compilers poll rather than being pushed
# to, so one that was down across a deploy catches up on its own with no event
# replayed to it.
#
# Unlike the dev control repo this lab replaced, `wire_server` defaults to **true**
# here. There is no dev environment to protect: a compiler in this lab exists only
# to serve codavox-distributed code, so staging the cutover would mean a node with
# no purpose until someone flipped a switch.
#
# That does mean OpenVox Server on this node serves *only* codavox environments —
# `codavox::server` repoints `environmentpath` rather than adding to it — and that
# catalog compilation here depends on the agent having converged. Both are the
# intended behavior; the lab is where that dependency should be exercised, not
# discovered.
#
# @param wire_server
#   Whether to point OpenVox Server at codavox. Set false only to reproduce the
#   staged-cutover path an existing estate would use.
class profile::codavox::compiler (
  Boolean $wire_server = true,
) {
  include codavox
  include codavox::agent

  if $wire_server {
    # profile::openvox_server already declares the service with attributes of its
    # own, so codavox must not declare it again. It notifies that declaration
    # through a resource collector instead.
    class { 'codavox::server':
      service_manage => false,
    }
  }
}

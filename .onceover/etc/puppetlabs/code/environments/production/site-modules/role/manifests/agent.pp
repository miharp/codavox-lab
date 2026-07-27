# @summary A plain managed node, pointed at a compiler.
#
# The end of the chain, and the only node that proves the point: it fetches a
# catalog from a compiler that is serving codavox-distributed code, so a
# successful run means the code_id, the artifact, the symlink swap, and
# code-content all held together.
#
# @example
#   include role::agent
class role::agent {
  include profile::base
}

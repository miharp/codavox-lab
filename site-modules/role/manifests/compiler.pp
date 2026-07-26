# @summary A compiler: compiles catalogs from codavox-distributed code.
#
# Runs the same server package as the primary and differs in what it may do: its
# CA service is disabled and it enrols against the primary's CA, so the estate has
# exactly one authority. That split happens during provisioning, because it must
# precede the node holding a certificate.
#
# Its certificate carries `pp_role: openvox_compiler`, written into
# `csr_attributes.yaml` before enrolment. The publisher authorizes on that
# extension, and it cannot be added afterwards without re-issuing the certificate.
#
# There are two of these in the lab on purpose. One compiler can only ever show
# convergence; two can show *divergence* — a deploy landing on one while the other
# is offline, and `codavox compilers` reporting them at different code_ids.
#
# @example
#   include role::compiler
class role::compiler {
  include profile::base
  include profile::openvox_server
  include profile::codavox::compiler
}

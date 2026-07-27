# @summary Baseline every node in the lab gets.
#
# Deliberately thin. This control repo exists to validate codavox, so the base
# profile carries only what is needed to prove a catalog compiled and applied —
# not a realistic production baseline.
#
# @param marker_content
#   Text written to the marker file. Set per environment in Hiera so a deploy can
#   be observed changing a node's applied state, not just its code_id.
class profile::base (
  String[1] $marker_content = 'default',
) {
  include profile::openvox_agent

  # A file rather than a notify: applying it proves the agent fetched *content*,
  # which on a static catalog means code-content resolved it out of the version
  # directory the code_id names.
  file { '/etc/codavox-lab-marker':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "${marker_content}\n",
  }
}

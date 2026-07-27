# @summary Pins the agent package version.
#
# @param version
#   The openvox-agent version to hold every node at. Version skew between an
#   agent and the server it talks to produces failures that look like code
#   problems, so the lab pins it rather than tracking latest.
class profile::openvox_agent (
  String[1] $version,
) {
  package { 'openvox-agent':
    ensure => $version,
  }
}

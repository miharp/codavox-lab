# @summary Installs OpenVox Server, on the primary and on every compiler.
#
# A compiler runs the same package as the primary. What differs is what it is
# allowed to do — its CA service is disabled and it enrols against the primary's
# CA — and that split is set up during provisioning, because it has to happen
# before the node holds a certificate at all.
#
# @param version
#   The openvox-server version to install.
class profile::openvox_server (
  String[1] $version,
) {
  $package_version = $facts['os']['family'] ? {
    'RedHat' => "${version}-1.el${facts['os']['release']['major']}",
    default  => $version,
  }

  package { 'openvox-server':
    ensure => $package_version,
  }

  # Declared here so codavox::server can notify it through a resource collector
  # when the versioned-code wiring changes, rather than each class racing to own
  # the service.
  service { 'puppetserver':
    ensure  => running,
    enable  => true,
    require => Package['openvox-server'],
  }
}

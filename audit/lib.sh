#!/bin/bash
# Shared by the host-side batches and the runner: what version of codavox the
# lab is installing, read from the same Hiera key the nodes install from.
#
# The pin is either a release URL or a snapshot rpm under dist/ (see
# scripts/use-snapshot). Two readers used to parse the URL independently, and
# they drifted once; now there is one.

# lab_pin prints the package_source value.
lab_pin() {
  sed -n "s|^codavox::package_source: *'\(.*\)'|\1|p" data/common.yaml | head -1
}

# lab_version prints the version `codavox version` will report on the nodes.
lab_version() {
  local pin
  pin=$(lab_pin)
  case "$pin" in
    */releases/download/v*) printf '%s\n' "$pin" | sed -n 's|.*/download/v\([0-9.]*\)/.*|\1|p' ;;
    /vagrant-src/dist/*)    awk '{print $1}' dist/VERSION 2>/dev/null ;;
  esac
}

# lab_version_label is lab_version plus, for a snapshot, the codavox commit it
# was built from, for the audit record.
lab_version_label() {
  local pin
  pin=$(lab_pin)
  case "$pin" in
    /vagrant-src/dist/*) awk '{print $1 "+" $2}' dist/VERSION 2>/dev/null ;;
    *) lab_version ;;
  esac
}

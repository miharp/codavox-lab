## site.pp ##
#
# The main manifest. Node definitions here must agree with spec/onceover.yaml:
# onceover proves a role compiles, never that a node is classified into it, so a
# role with no matching definition here silently never runs.

File { backup => false }

# Anything unclassified gets the baseline only. Reaching this is a sign a node
# definition is missing, so the marker content says so rather than looking healthy.
node default {
  include profile::base
}

node 'puppet.example.com' {
  include role::primary
}

node 'compiler01.example.com', 'compiler02.example.com' {
  include role::compiler
}

node 'agent01.example.com' {
  include role::agent
}

RSpec.configure do |c|
  c.mock_with :rspec
end

require 'rspec_junit_formatter'
require 'onceover/rspec/formatters'

RSpec.configure do |c|
  # Create onceover settings to be accessed by formatters
  c.add_setting :onceover_tempdir
  c.add_setting :onceover_root
  c.add_setting :onceover_environmentpath

  c.onceover_tempdir         = "/Users/michaelharp/projects/codavox-lab/.onceover"
  c.onceover_root            = "/Users/michaelharp/projects/codavox-lab"
  c.onceover_environmentpath = "etc/puppetlabs/code/environments"

  # Also add JUnit output in case people want to use that
  c.add_formatter('RSpecJUnitFormatter','/Users/michaelharp/projects/codavox-lab/.onceover/spec.xml')

  c.formatter             = 'OnceoverFormatter'
  c.environmentpath       = '/Users/michaelharp/projects/codavox-lab/.onceover/etc/puppetlabs/code/environments'
  c.module_path           = '/Users/michaelharp/projects/codavox-lab/.onceover/etc/puppetlabs/code/environments/production/site-modules:/Users/michaelharp/projects/codavox-lab/.onceover/etc/puppetlabs/code/environments/production/modules'

  c.hiera_config          = '/Users/michaelharp/projects/codavox-lab/.onceover/etc/puppetlabs/code/environments/production/hiera.yaml'
  c.manifest              = ''
  ENV['STRICT_VARIABLES'] = 'no'
end

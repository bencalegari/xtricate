require "ostruct"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

# Load only what the specs touch. The renderer depends on the models but not on
# the network/Claude layers, so we avoid requiring the full "xtricate" entry
# point (which pulls in the anthropic SDK et al).
require "xtricate/models"
require "xtricate/renderer"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand(config.seed)
end

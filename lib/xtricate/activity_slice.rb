require_relative "models"
require_relative "thread_assembly"

module Xtricate
  module ActivitySlice
    module_function

    def for(subscriber, activities)
      since = subscriber.since

      slice = activities.filter_map do |a|
        next unless subscriber.follows?(a.handle, a.source)

        tweets = (a.tweets || []).select { |t| t.created_at.nil? || t.created_at >= since }.map(&:dup)
        AccountActivity.new(handle: a.handle, source: a.source, tweets: tweets)
      end

      ThreadAssembly.assemble!(slice)
    end
  end
end

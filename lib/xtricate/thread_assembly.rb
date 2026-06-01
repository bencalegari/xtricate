require_relative "models"

module Xtricate
  # Detects self-threads within a single account's recent posts and collapses
  # them so the rest of the pipeline (Claude payload, themes, rendering) sees
  # *one* unit per thread instead of N disjoint tweets.
  #
  # A "self-thread" is a run of original/quote posts by the same author that
  # share the same conversation_id (i.e. the author kept replying to their own
  # earlier post in the same conversation). Retweets are never threaded — they
  # represent someone else's content, so we leave them alone.
  #
  # The thread head (oldest post) carries `thread_continuations` (an array of
  # the rest in chronological order). All continuations get `thread_root_id`
  # set to the head's id so the digest can drop them from its top-level list.
  module ThreadAssembly
    module_function

    # Mutates and returns the same activities array.
    def assemble!(activities)
      activities.each { |a| assemble_account!(a) }
      activities
    end

    def assemble_account!(activity)
      return if activity.empty?

      # Only consider originals + quotes; retweets are never thread members.
      threadable = activity.tweets.select { |t| t.kind != :retweet && t.conversation_id }
      grouped = threadable.group_by { |t| t.conversation_id }

      grouped.each_value do |group|
        next if group.size < 2

        sorted = group.sort_by { |t| t.created_at || Time.at(0) }
        head = sorted.first
        rest = sorted[1..]

        head.thread_root_id  = head.id
        head.thread_position = 0
        head.thread_continuations = rest

        rest.each_with_index do |t, i|
          t.thread_root_id = head.id
          t.thread_position = i + 1
          t.thread_continuations = nil
        end
      end
    end
  end
end

module Xtricate
  class Throttle
    def initialize(qps:, clock: nil, sleeper: nil)
      raise ArgumentError, "qps must be positive" unless qps.to_f.positive?

      @interval = 1.0 / qps
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @mutex = Mutex.new
      @next_slot = nil
    end

    def acquire
      wait = @mutex.synchronize do
        now = @clock.call
        @next_slot = now if @next_slot.nil? || @next_slot < now
        slot = @next_slot
        @next_slot = slot + @interval
        slot - now
      end
      @sleeper.call(wait) if wait.positive?
      nil
    end
  end

  module Pool
    module_function

    def map(items, threads:, &block)
      items = items.to_a
      return [] if items.empty?

      size = [threads, items.size].min
      size = 1 if size < 1
      results = Array.new(items.size)
      errors = []
      errors_lock = Mutex.new
      queue = Queue.new
      items.each_with_index { |item, index| queue << [index, item] }
      size.times { queue << nil }

      Array.new(size) do
        Thread.new do
          while (job = queue.pop)
            index, item = job
            begin
              results[index] = block.call(item)
            rescue StandardError => e
              errors_lock.synchronize { errors << [index, e] }
            end
          end
        end
      end.each(&:join)

      raise errors.min_by(&:first).last if errors.any?

      results
    end
  end
end

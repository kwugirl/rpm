# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

module NewRelic
  module Agent
    module Threading
      class BacktraceService
        ALL_TRANSACTIONS = "**ALL**".freeze

        def self.is_supported?
          NewRelic::Agent.logger.debug "JMS: BacktraceService.is_supported? RUBY_VERSION: #{RUBY_VERSION}, RUBY_VERSION >= '1.9.2': #{RUBY_VERSION >= '1.9.2'}"
          RUBY_VERSION >= "1.9.2"
        end

        attr_reader :worker_loop, :buffer, :effective_polling_period,
                    :overhead_percent_threshold
        attr_accessor :worker_thread, :profile_agent_code

        def initialize(event_listener=nil)
          @profiles = {}
          @buffer = {}

          # synchronizes access to @profiles and @buffer above
          @lock = Mutex.new

          @running = false
          @profile_agent_code = false
          @worker_loop = NewRelic::Agent::WorkerLoop.new

          # Memoize overhead % to avoid getting stale OR looked up every poll
          @overhead_percent_threshold = NewRelic::Agent.config[:'xray_session.max_profile_overhead']
          NewRelic::Agent.config.register_callback(:'xray_session.max_profile_overhead') do |new_value|
            @overhead_percent_threshold = new_value
          end

          if event_listener
            event_listener.subscribe(:transaction_finished, &method(:on_transaction_finished))
          end
        end

        # Public interface

        def running?
          @running
        end

        def subscribe(transaction_name, command_arguments={})
          if !self.class.is_supported?
            NewRelic::Agent.logger.debug("Backtracing not supported, so not subscribing transaction '#{transaction_name}'")
            return
          end

          NewRelic::Agent.logger.debug("Backtrace Service subscribing transaction '#{transaction_name}'")

          profile = ThreadProfile.new(command_arguments)

          @lock.synchronize do
            @profiles[transaction_name] = profile
            update_values_from_profiles
          end

          start
          profile
        end

        def unsubscribe(transaction_name)
          return unless self.class.is_supported?

          NewRelic::Agent.logger.debug("Backtrace Service unsubscribing transaction '#{transaction_name}'")
          @lock.synchronize do
            @profiles.delete(transaction_name)
            if @profiles.empty?
              stop
            else
              update_values_from_profiles
            end
          end
        end

        def update_values_from_profiles
          self.effective_polling_period = find_effective_polling_period
          self.profile_agent_code = should_profile_agent_code?
        end

        def subscribed?(transaction_name)
          @lock.synchronize do
            @profiles.has_key?(transaction_name)
          end
        end

        def harvest(transaction_name)
          @lock.synchronize do
            if @profiles[transaction_name]
              profile = @profiles.delete(transaction_name)
              profile.finished_at = Time.now
              @profiles[transaction_name] = ThreadProfile.new(profile.command_arguments)
              profile
            end
          end
        end

        def on_transaction_finished(payload)
          name     = payload[:name]
          start    = payload[:start_timestamp]
          duration = payload[:duration]
          thread   = payload[:thread] || Thread.current
          @lock.synchronize do
            backtraces = @buffer.delete(thread)
            if backtraces && @profiles.has_key?(name)
              aggregate_backtraces(backtraces, name, start, duration, thread)
            end
          end
        end

        # Internals

        # This method is expected to be called with @lock held.
        def aggregate_backtraces(backtraces, name, start, duration, thread)
          end_time = start + duration
          backtraces.each do |(timestamp, backtrace)|
            if timestamp >= start && timestamp < end_time
              @profiles[name].aggregate(backtrace, :request, thread)
            end
          end
        end

        def start
          return if @running || !self.class.is_supported?

          @running = true
          self.worker_thread = AgentThread.new('Backtrace Service') do
            begin
              # Not passing period because we expect it's already been set.
              self.worker_loop.run(&method(:poll))
            ensure
              NewRelic::Agent.logger.debug("Exiting New Relic thread: Backtrace Service")
            end
          end
        end

        # This method is expected to be called with @lock held
        def stop
          return unless @running
          @running = false
          self.worker_loop.stop

          @buffer = {}
        end

        def effective_polling_period=(new_period)
          @effective_polling_period = new_period
          self.worker_loop.period = new_period
        end

        def poll
          poll_start = Time.now

          @lock.synchronize do
            AgentThread.list.each do |thread|
              sample_thread(thread)
            end
            @profiles.each_value { |p| p.increment_poll_count }
            @buffer.delete_if { |thread, _| !thread.alive? }
          end

          end_time = Time.now
          adjust_polling_time(end_time, poll_start)
          record_supportability_metrics(end_time, poll_start)
        end

        # This method is expected to be called with @lock held.
        attr_reader :profiles

        # This method is expected to be called with @lock held.
        def should_buffer?(bucket)
          bucket == :request && @profiles.keys.any? { |k| k != ALL_TRANSACTIONS }
        end

        # This method is expected to be called with @lock held.
        def need_backtrace?(bucket)
          (
            bucket != :ignore &&
            (@profiles[ALL_TRANSACTIONS] || should_buffer?(bucket))
          )
        end

        MAX_BUFFER_LENGTH = 500

        # This method is expected to be called with @lock held.
        def buffer_backtrace_for_thread(thread, timestamp, backtrace, bucket)
          if should_buffer?(bucket)
            @buffer[thread] ||= []
            if @buffer[thread].length < MAX_BUFFER_LENGTH
              @buffer[thread] << [timestamp, backtrace]
            else
              NewRelic::Agent.increment_metric('Supportability/XraySessions/DroppedBacktraces')
            end
          end
        end

        # This method is expected to be called with @lock held.
        def aggregate_global_backtrace(backtrace, bucket, thread)
          if @profiles[ALL_TRANSACTIONS]
            @profiles[ALL_TRANSACTIONS].aggregate(backtrace, bucket, thread)
          end
        end

        # This method is expected to be called with @lock held.
        def sample_thread(thread)
          bucket = AgentThread.bucket_thread(thread, @profile_agent_code)

          if need_backtrace?(bucket)
            timestamp = Time.now.to_f
            backtrace = AgentThread.scrub_backtrace(thread, @profile_agent_code)
            aggregate_global_backtrace(backtrace, bucket, thread)
            buffer_backtrace_for_thread(thread, timestamp, backtrace, bucket)
          end
        end

        # This method is expected to be called with @lock held.
        def find_effective_polling_period
          @profiles.values.map { |p| p.requested_period }.min
        end

        # This method is expected to be called with @lock held.
        def should_profile_agent_code?
          @profiles.values.any? { |p| p.profile_agent_code }
        end

        # If our overhead % exceeds the threshold, bump the next poll period
        # relative to how much larger our overhead is than allowed
        def adjust_polling_time(now, poll_start)
          duration = now - poll_start
          overhead_percent = duration / effective_polling_period

          if overhead_percent > self.overhead_percent_threshold
            scale_up_by = overhead_percent / self.overhead_percent_threshold
            worker_loop.period = effective_polling_period * scale_up_by
          else
            worker_loop.period = effective_polling_period
          end
        end

        def record_supportability_metrics(now, poll_start)
          record_polling_time(now, poll_start)
          record_skew(poll_start)
        end

        def record_polling_time(now, poll_start)
          NewRelic::Agent.record_metric('Supportability/ThreadProfiler/PollingTime', now - poll_start)
        end

        def record_skew(poll_start)
          if @last_poll
            skew = poll_start - @last_poll - worker_loop.period
            NewRelic::Agent.record_metric('Supportability/ThreadProfiler/Skew', skew)
          end
          @last_poll = poll_start
        end

      end
    end
  end
end

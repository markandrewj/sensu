require File.join(File.dirname(__FILE__), 'base')
require File.join(File.dirname(__FILE__), 'redis')
require File.join(File.dirname(__FILE__), 'socket')
require File.join(File.dirname(__FILE__), 'sandbox')

module Sensu
  class Server
    include Utilities

    attr_reader :is_master

    def self.run(options={})
      server = self.new(options)
      EM::run do
        server.start
        server.trap_signals
      end
    end

    def initialize(options={})
      base = Base.new(options)
      @logger = base.logger
      @settings = base.settings
      @extensions = base.extensions
      base.setup_process
      @timers = Array.new
      @master_timers = Array.new
      @handlers_in_progress_count = 0
      @is_master = false
    end

    def setup_redis
      @logger.debug('connecting to redis', {
        :settings => @settings[:redis]
      })
      @redis = Redis.connect(@settings[:redis])
      @redis.on_error do |error|
        @logger.fatal('redis connection error', {
          :error => error.to_s
        })
        stop
      end
      @redis.before_reconnect do
        @logger.warn('reconnecting to redis')
        unless testing?
          pause
        end
      end
      @redis.after_reconnect do
        @logger.info('reconnected to redis')
        resume
      end
    end

    def setup_rabbitmq
      @logger.debug('connecting to rabbitmq', {
        :settings => @settings[:rabbitmq]
      })
      @rabbitmq = RabbitMQ.connect(@settings[:rabbitmq])
      @rabbitmq.on_error do |error|
        @logger.fatal('rabbitmq connection error', {
          :error => error.to_s
        })
        stop
      end
      @rabbitmq.before_reconnect do
        @logger.warn('reconnecting to rabbitmq')
        resign_as_master
      end
      @rabbitmq.after_reconnect do
        @logger.info('reconnected to rabbitmq')
        @amq.prefetch(1)
      end
      @amq = @rabbitmq.channel
      @amq.prefetch(1)
    end

    def setup_keepalives
      @logger.debug('subscribing to keepalives')
      @amq.queue('keepalives').consumers.each do |consumer_tag, consumer|
        consumer.cancel
      end
      @keepalive_queue = @amq.queue!('keepalives')
      @keepalive_queue.subscribe(:ack => true) do |header, payload|
        client = JSON.parse(payload, :symbolize_names => true)
        @logger.debug('received keepalive', {
          :client => client
        })
        @redis.set('client:' + client[:name], client.to_json) do
          @redis.sadd('clients', client[:name]) do
            header.ack
          end
        end
      end
    end

    def check_subdued?(check, subdue_at)
      subdue = false
      if check[:subdue].is_a?(Hash)
        if check[:subdue].has_key?(:begin) && check[:subdue].has_key?(:end)
          begin_time = Time.parse(check[:subdue][:begin])
          end_time = Time.parse(check[:subdue][:end])
          if end_time < begin_time
            if Time.now < end_time
              begin_time = Time.parse('12:00:00 AM')
            else
              end_time = Time.parse('11:59:59 PM')
            end
          end
          if Time.now >= begin_time && Time.now <= end_time
            subdue = true
          end
        end
        if check[:subdue].has_key?(:days)
          days = check[:subdue][:days].map(&:downcase)
          if days.include?(Time.now.strftime('%A').downcase)
            subdue = true
          end
        end
        if subdue && check[:subdue].has_key?(:exceptions)
          subdue = check[:subdue][:exceptions].none? do |exception|
            Time.now >= Time.parse(exception[:begin]) && Time.now <= Time.parse(exception[:end])
          end
        end
      end
      subdue && subdue_at == (check[:subdue][:at] || 'handler').to_sym
    end

    def filter_attributes_match?(hash_one, hash_two)
      hash_one.keys.all? do |key|
        case
        when hash_one[key] == hash_two[key]
          true
        when hash_one[key].is_a?(Hash) && hash_two[key].is_a?(Hash)
          filter_attributes_match?(hash_one[key], hash_two[key])
        when hash_one[key].is_a?(String) && hash_one[key].start_with?('eval:')
          begin
            expression = hash_one[key].gsub(/^eval:(\s+)?/, '')
            !!Sandbox.eval(expression, hash_two[key])
          rescue
            false
          end
        else
          false
        end
      end
    end

    def event_filtered?(filter_name, event)
      if @settings.filter_exists?(filter_name)
        filter = @settings[:filters][filter_name]
        matched = filter_attributes_match?(filter[:attributes], event)
        filter[:negate] ? matched : !matched
      else
        @logger.error('unknown filter', {
          :filter => {
            :name => filter_name
          }
        })
        false
      end
    end

    def derive_handlers(handler_list, nested=false)
      handler_list.inject(Array.new) do |handlers, handler_name|
        if @settings.handler_exists?(handler_name)
          handler = @settings[:handlers][handler_name].merge(:name => handler_name)
          if handler[:type] == 'set'
            unless nested
              handlers = handlers + derive_handlers(handler[:handlers], true)
            else
              @logger.error('handler sets cannot be nested', {
                :handler => handler
              })
            end
          else
            handlers.push(handler)
          end
        elsif @extensions.handler_exists?(handler_name)
          handler = @extensions[:handlers][handler_name]
          handlers.push(handler)
        else
          @logger.error('unknown handler', {
            :handler => {
              :name => handler_name
            }
          })
        end
        handlers.uniq
      end
    end

    def event_handlers(event)
      handler_list = Array((event[:check][:handlers] || event[:check][:handler]) || 'default')
      handlers = derive_handlers(handler_list)
      event_severity = SEVERITIES[event[:check][:status]] || 'unknown'
      handlers.select do |handler|
        if event[:action] == :flapping && !handler[:handle_flapping]
          @logger.info('handler does not handle flapping events', {
            :event => event,
            :handler => handler
          })
          next
        end
        if check_subdued?(event[:check], :handler)
          @logger.info('check is subdued at handler', {
            :event => event,
            :handler => handler
          })
          next
        end
        if handler.has_key?(:severities) && !handler[:severities].include?(event_severity)
          unless event[:action] == :resolve
            @logger.debug('handler does not handle event severity', {
              :event => event,
              :handler => handler
            })
            next
          end
        end
        if handler.has_key?(:filters) || handler.has_key?(:filter)
          filter_list = Array(handler[:filters] || handler[:filter])
          filtered = filter_list.any? do |filter_name|
            event_filtered?(filter_name, event)
          end
          if filtered
            @logger.info('event filtered for handler', {
              :event => event,
              :handler => handler
            })
            next
          end
        end
        true
      end
    end

    def execute_command(command, data=nil, on_error=nil, &block)
      on_error ||= Proc.new do |error|
        @logger.error('failed to execute command', {
          :command => command,
          :data => data,
          :error => error.to_s
        })
      end
      execute = Proc.new do
        begin
          output, status = IO.popen(command, 'r+') do |child|
            unless data.nil?
              child.write(data.to_s)
            end
            child.close_write
          end
          [true, output, status]
        rescue => error
          on_error.call(error)
          [false, nil, nil]
        end
      end
      complete = Proc.new do |success, output, status|
        if success
          block.call(output, status)
        end
      end
      EM::defer(execute, complete)
    end

    def mutate_event_data(mutator_name, event, &block)
      on_error = Proc.new do |error|
        @logger.error('mutator error', {
          :event => event,
          :mutator => mutator,
          :error => error.to_s
        })
      end
      case
      when mutator_name.nil?
        block.call(event.to_json)
      when @settings.mutator_exists?(mutator_name)
        mutator = @settings[:mutators][mutator_name]
        execute_command(mutator[:command], event.to_json, on_error) do |output, status|
          if status == 0
            block.call(output)
          else
            on_error.call('non-zero exit status (' + status + '): ' + output)
          end
        end
      when @extensions.mutator_exists?(mutator_name)
        @extensions[:mutators][mutator_name].run(event, @settings.to_hash) do |output, status|
          if status == 0
            block.call(output)
          else
            on_error.call('non-zero exit status (' + status + '): ' + output)
          end
        end
      else
        @logger.error('unknown mutator', {
          :mutator => {
            :name => mutator_name
          }
        })
      end
    end

    def handle_event(event)
      handlers = event_handlers(event)
      handlers.each do |handler|
        log_level = event[:check][:type] == 'metric' ? :debug : :info
        @logger.send(log_level, 'handling event', {
          :event => event,
          :handler => handler
        })
        @handlers_in_progress_count += 1
        on_error = Proc.new do |error|
          @logger.error('handler error', {
            :event => event,
            :handler => handler,
            :error => error.to_s
          })
          @handlers_in_progress_count -= 1
        end
        mutate_event_data(handler[:mutator], event) do |event_data|
          case handler[:type]
          when 'pipe'
            execute_command(handler[:command], event_data, on_error) do |output, status|
              output.split(/\n+/).each do |line|
                @logger.info(line)
              end
              @handlers_in_progress_count -= 1
            end
          when 'tcp'
            begin
              EM::connect(handler[:socket][:host], handler[:socket][:port], SocketHandler) do |socket|
                socket.on_success = Proc.new do
                  @handlers_in_progress_count -= 1
                end
                socket.on_error = on_error
                timeout = handler[:socket][:timeout] || 10
                socket.pending_connect_timeout = timeout
                socket.comm_inactivity_timeout = timeout
                socket.send_data(event_data.to_s)
                socket.close_connection_after_writing
              end
            rescue => error
              on_error.call(error)
            end
          when 'udp'
            begin
              EM::open_datagram_socket('127.0.0.1', 0, nil) do |socket|
                socket.send_datagram(event_data.to_s, handler[:socket][:host], handler[:socket][:port])
                socket.close_connection_after_writing
                @handlers_in_progress_count -= 1
              end
            rescue => error
              on_error.call(error)
            end
          when 'amqp'
            exchange_name = handler[:exchange][:name]
            exchange_type = handler[:exchange].has_key?(:type) ? handler[:exchange][:type].to_sym : :direct
            exchange_options = handler[:exchange].reject do |key, value|
              [:name, :type].include?(key)
            end
            unless event_data.empty?
              @amq.method(exchange_type).call(exchange_name, exchange_options).publish(event_data)
            end
            @handlers_in_progress_count -= 1
          when 'extension'
            handler.run(event_data, @settings.to_hash) do |output, status|
              output.split(/\n+/).each do |line|
                @logger.info(line)
              end
              @handlers_in_progress_count -= 1
            end
          end
        end
      end
    end

    def aggregate_result(result)
      @logger.debug('adding result to aggregate', {
        :result => result
      })
      check = result[:check]
      result_set = check[:name] + ':' + check[:issued].to_s
      @redis.hset('aggregation:' + result_set, result[:client], {
        :output => check[:output],
        :status => check[:status]
      }.to_json) do
        SEVERITIES.each do |severity|
          @redis.hsetnx('aggregate:' + result_set, severity, 0)
        end
        severity = (SEVERITIES[check[:status]] || 'unknown')
        @redis.hincrby('aggregate:' + result_set, severity, 1) do
          @redis.hincrby('aggregate:' + result_set, 'total', 1) do
            @redis.sadd('aggregates:' + check[:name], check[:issued]) do
              @redis.sadd('aggregates', check[:name])
            end
          end
        end
      end
    end

    def process_result(result)
      @logger.debug('processing result', {
        :result => result
      })
      @redis.get('client:' + result[:client]) do |client_json|
        unless client_json.nil?
          client = JSON.parse(client_json, :symbolize_names => true)
          check = case
          when @settings.check_exists?(result[:check][:name])
            @settings[:checks][result[:check][:name]].merge(result[:check])
          else
            result[:check]
          end
          if check[:aggregate]
            aggregate_result(result)
          end
          @redis.sadd('history:' + client[:name], check[:name])
          history_key = 'history:' + client[:name] + ':' + check[:name]
          @redis.rpush(history_key, check[:status]) do
            @redis.lrange(history_key, -21, -1) do |history|
              check[:history] = history
              total_state_change = 0
              unless history.size < 21
                state_changes = 0
                change_weight = 0.8
                previous_status = history.first
                history.each do |status|
                  unless status == previous_status
                    state_changes += change_weight
                  end
                  change_weight += 0.02
                  previous_status = status
                end
                total_state_change = (state_changes.fdiv(20) * 100).to_i
                @redis.ltrim(history_key, -21, -1)
              end
              @redis.hget('events:' + client[:name], check[:name]) do |event_json|
                previous_occurrence = event_json ? JSON.parse(event_json, :symbolize_names => true) : false
                is_flapping = false
                if check.has_key?(:low_flap_threshold) && check.has_key?(:high_flap_threshold)
                  was_flapping = previous_occurrence ? previous_occurrence[:flapping] : false
                  is_flapping = case
                  when total_state_change >= check[:high_flap_threshold]
                    true
                  when was_flapping && total_state_change <= check[:low_flap_threshold]
                    false
                  else
                    was_flapping
                  end
                end
                event = {
                  :client => client,
                  :check => check,
                  :occurrences => 1
                }
                if check[:status] != 0 || is_flapping
                  if previous_occurrence && check[:status] == previous_occurrence[:status]
                    event[:occurrences] = previous_occurrence[:occurrences] += 1
                  end
                  @redis.hset('events:' + client[:name], check[:name], {
                    :output => check[:output],
                    :status => check[:status],
                    :issued => check[:issued],
                    :handlers => Array((check[:handlers] || check[:handler]) || 'default'),
                    :flapping => is_flapping,
                    :occurrences => event[:occurrences]
                  }.to_json) do
                    unless check[:handle] == false
                      event[:action] = is_flapping ? :flapping : :create
                      handle_event(event)
                    end
                  end
                elsif previous_occurrence
                  unless check[:auto_resolve] == false && !check[:force_resolve]
                    @redis.hdel('events:' + client[:name], check[:name]) do
                      unless check[:handle] == false
                        event[:occurrences] = previous_occurrence[:occurrences]
                        event[:action] = :resolve
                        handle_event(event)
                      end
                    end
                  end
                elsif check[:type] == 'metric'
                  handle_event(event)
                end
              end
            end
          end
        end
      end
    end

    def setup_results
      @logger.debug('subscribing to results')
      @amq.queue('results').consumers.each do |consumer_tag, consumer|
        consumer.cancel
      end
      @result_queue = @amq.queue!('results')
      @result_queue.subscribe(:ack => true) do |header, payload|
        result = JSON.parse(payload, :symbolize_names => true)
        @logger.debug('received result', {
          :result => result
        })
        process_result(result)
        EM::next_tick do
          header.ack
        end
      end
    end

    def publish_check_request(check)
      payload = {
        :name => check[:name],
        :command => check[:command],
        :issued => Time.now.to_i
      }
      @logger.info('publishing check request', {
        :payload => payload,
        :subscribers => check[:subscribers]
      })
      check[:subscribers].uniq.each do |exchange_name|
        @amq.fanout(exchange_name).publish(payload.to_json)
      end
    end

    def setup_publisher
      @logger.debug('scheduling check requests')
      check_count = 0
      stagger = testing? ? 0 : 2
      @settings.checks.each do |check|
        unless check[:publish] == false || check[:standalone]
          check_count += 1
          scheduling_delay = stagger * check_count % 30
          @master_timers << EM::Timer.new(scheduling_delay) do
            interval = testing? ? 0.5 : check[:interval]
            @master_timers << EM::PeriodicTimer.new(interval) do
              unless check_subdued?(check, :publisher)
                publish_check_request(check)
              end
            end
          end
        end
      end
    end

    def publish_result(client, check)
      payload = {
        :client => client[:name],
        :check => check
      }
      @logger.info('publishing check result', {
        :payload => payload
      })
      @amq.queue('results').publish(payload.to_json)
    end

    def determine_stale_clients
      @logger.info('determining stale clients')
      @redis.smembers('clients') do |clients|
        clients.each do |client_name|
          @redis.get('client:' + client_name) do |client_json|
            client = JSON.parse(client_json, :symbolize_names => true)
            check = {
              :name => 'keepalive',
              :issued => Time.now.to_i
            }
            time_since_last_keepalive = Time.now.to_i - client[:timestamp]
            case
            when time_since_last_keepalive >= 180
              check[:output] = 'No keep-alive sent from client in over 180 seconds'
              check[:status] = 2
              publish_result(client, check)
            when time_since_last_keepalive >= 120
              check[:output] = 'No keep-alive sent from client in over 120 seconds'
              check[:status] = 1
              publish_result(client, check)
            else
              @redis.hexists('events:' + client[:name], 'keepalive') do |exists|
                if exists
                  check[:output] = 'Keep-alive sent from client'
                  check[:status] = 0
                  publish_result(client, check)
                end
              end
            end
          end
        end
      end
    end

    def setup_client_monitor
      @logger.debug('monitoring clients')
      @master_timers << EM::PeriodicTimer.new(30) do
        determine_stale_clients
      end
    end

    def prune_aggregations
      @logger.info('pruning aggregations')
      @redis.smembers('aggregates') do |checks|
        checks.each do |check_name|
          @redis.smembers('aggregates:' + check_name) do |aggregates|
            if aggregates.size > 20
              aggregates.sort!
              aggregates.take(aggregates.size - 20).each do |check_issued|
                @redis.srem('aggregates:' + check_name, check_issued) do
                  result_set = check_name + ':' + check_issued.to_s
                  @redis.del('aggregate:' + result_set) do
                    @redis.del('aggregation:' + result_set) do
                      @logger.debug('pruned aggregation', {
                        :check => {
                          :name => check_name,
                          :issued => check_issued
                        }
                      })
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    def setup_aggregation_pruner
      @logger.debug('pruning aggregations')
      @master_timers << EM::PeriodicTimer.new(20) do
        prune_aggregations
      end
    end

    def master_duties
      setup_publisher
      setup_client_monitor
      setup_aggregation_pruner
    end

    def request_master_election
      @redis.setnx('lock:master', Time.now.to_i) do |created|
        if created
          @is_master = true
          @logger.info('i am the master')
          master_duties
        else
          @redis.get('lock:master') do |timestamp|
            if Time.now.to_i - timestamp.to_i >= 60
              @redis.getset('lock:master', Time.now.to_i) do |previous|
                if previous == timestamp
                  @is_master = true
                  @logger.info('i am now the master')
                  master_duties
                end
              end
            end
          end
        end
      end
    end

    def setup_master_monitor
      request_master_election
      @timers << EM::PeriodicTimer.new(20) do
        if @is_master
          @redis.set('lock:master', Time.now.to_i) do
            @logger.debug('updated master lock timestamp')
          end
        elsif @rabbitmq.connected?
          request_master_election
        end
      end
    end

    def resign_as_master(&block)
      block ||= Proc.new {}
      if @is_master
        @logger.warn('resigning as master')
        @master_timers.each do |timer|
          timer.cancel
        end
        @master_timers = Array.new
        if @redis.connected?
          @redis.del('lock:master') do
            @logger.info('removed master lock')
            @is_master = false
          end
        end
        timestamp = Time.now.to_i
        retry_until_true do
          if !@is_master
            block.call
            true
          elsif Time.now.to_i - timestamp >= 3
            @logger.warn('failed to remove master lock')
            @is_master = false
            block.call
            true
          end
        end
      else
        @logger.debug('not currently master')
        block.call
      end
    end

    def unsubscribe(&block)
      @logger.warn('unsubscribing from keepalive and result queues')
      @keepalive_queue.unsubscribe
      @result_queue.unsubscribe
      if @rabbitmq.connected?
        @amq.recover
        timestamp = Time.now.to_i
        retry_until_true do
          if !@keepalive_queue.subscribed? && !@result_queue.subscribed?
            block.call
            true
          elsif Time.now.to_i - timestamp >= 5
            @logger.warn('failed to unsubscribe from keepalive and result queues')
            block.call
            true
          end
        end
      else
        block.call
      end
    end

    def complete_handlers_in_progress(&block)
      @logger.info('completing handlers in progress', {
        :handlers_in_progress_count => @handlers_in_progress_count
      })
      retry_until_true do
        if @handlers_in_progress_count == 0
          block.call
          true
        end
      end
    end

    def bootstrap
      setup_keepalives
      setup_results
      setup_master_monitor
      @state = :running
    end

    def start
      setup_redis
      setup_rabbitmq
      bootstrap
    end

    def pause(&block)
      unless @state == :pausing || @state == :paused
        @state = :pausing
        @timers.each do |timer|
          timer.cancel
        end
        @timers = Array.new
        unsubscribe do
          resign_as_master do
            @state = :paused
            if block
              block.call
            end
          end
        end
      end
    end

    def resume
      retry_until_true(1) do
        if @state == :paused
          if @redis.connected? && @rabbitmq.connected?
            bootstrap
            true
          end
        end
      end
    end

    def stop
      @logger.warn('stopping')
      @state = :stopping
      pause do
        complete_handlers_in_progress do
          @redis.close
          @rabbitmq.close
          @logger.warn('stopping reactor')
          EM::stop_event_loop
        end
      end
    end

    def trap_signals
      %w[INT TERM].each do |signal|
        Signal.trap(signal) do
          @logger.warn('received signal', {
            :signal => signal
          })
          stop
        end
      end
    end
  end
end

#!/usr/bin/env ruby
require 'rubygems'
require 'eventmachine'
require 'logger'
require 'em-http'

module HttpLoader

  class Request
    def initialize(base_url, action)
      @base_url, @action = base_url, action
    end

    def verb
      return @verb if defined?(@verb)
      if /http_(get|put|post|delete)/.match(@action.usr_action.to_s)
        @verb = $1
      else
        raise "unknown HTTP use action '#{@action.usr_action.to_s}'"
      end
      @verb
    end

    def url
      return @url if defined?(@url)
      url = @action.url if @action
      url = "/" unless url

      # Make sure the URL starts with "/"
      url = "/" + url unless url[0,1] == "/"
      url = @base_url + url

      begin
        # Are there any values we need to substitute (or buffers we need to send)?
        if @action.rndval_min or @action.rndval_max
          # Make up a random number in the given range
          lower_bound = @action.rndval_min.to_i
          upper_bound = @action.rndval_max.to_i
        else
          lower_bound = @action.value
          upper_bound = @action.value
        end
        # See if we need to substitute "val" anywhere in the URL
        while pos = url.index("[VALUE]")
          url[pos, 7] = (lower_bound + rand(upper_bound - lower_bound).to_i).to_s
        end
      rescue
      end
      @url = url
    end

    def body
      return @body if defined?(@body)
      # Do we need to create a bunch of data to send?
      begin
        if @action.rnddsz_min or @action.rnddsz_max
          # Make up a random number in the given range
          lower_bound = @action.rnddsz_min.to_i
          upper_bound = @action.rnddsz_max.to_i
          data_length = (lower_bound + rand(upper_bound - lower_bound).to_i) + 1
        else
          data_length = @action.data_size
        end
        @body = data_length ? "*" * data_length : nil
      rescue
        @body = nil
      end
    end
  end

  class RandomMix
    
    attr_reader :count
    
    def initialize(base_url, actions)
      @base_url = base_url
      @actions = actions
      @count = 0
      
      @lock  = Mutex.new
      
      @fractions = []
      higher = lower = 0
      
      actions.each do |action|
        higher += action.fraction
        @fractions << [lower, higher]
        lower = higher
      end
      raise "sum of :fraction values in use mix not equal to 100" if higher != 100

      # Create an array of 100 entries with each mix entry in proportion
      #@actions = []
      #actions.each { |action| @actions += [action] * action.fraction }
      #raise "sum of :fraction values in use mix not equal to 100" if @actions.length != 100
    end

    def next
      @lock.synchronize {
        rand_num = STAC::SeedManager.get_random(@count) % 100
        @count += 1
        
        @fractions.each_with_index do |scope, i|
          return Request.new(@base_url, @actions[i]) if rand_num>=scope[0] and rand_num<scope[1]
        end
      }
    end
  end

  class StaticMix
    
    attr_reader :count
    
    def initialize(base_url, action, url)
      @base_url = base_url
      @count    = 0
      @mutex    = Mutex.new

      # We have only a single action, remember it
      @action = action
    end

    def next
      @mutex.synchronize {
        @count += 1
        Request.new(@base_url, @action)
      }
    end
  end

  class LoadGenerator
    attr_reader :stats

    def initialize(logger)
      @logger     = logger
      @stop_test  = false
      @stopped    = false
      @mutex      = Mutex.new
      @stopped_cv = ConditionVariable.new

      # Initialize the global stats
      @stats = {}
      @stats[:inflight]           = 0
      @stats[:requests]           = 0
      @stats[:failures]           = 0
      @stats[:bytes_sent]         = 0
      @stats[:bytes_rcvd]         = 0
      @stats[:total_time]         = 0
      @stats[:recent_ops_per_sec] = 0
    end

    def self.format_size(size)
      return "#{size} B" if size < 4 * 1024
      size = (size + 511) / 1024
      return "#{size}KB" if size < 4 * 1024
      size = (size + 511) / 1024
      return "#{size}MB" if size < 4 * 1024
      size = (size + 511) / 1024
      return "#{size}GB" if size < 4 * 1024
      "#{size} B"
    end

    def self.format_stats(stats)
      if stats[:requests] > 0
        avg_ms = "%u" % (stats[:total_time] * 1000.0 / stats[:requests]).to_i
      else
        avg_ms = "NA"
      end

      rslt = "#{stats[:requests]} HTTP requests"
      rslt += ": #{avg_ms} msec avg"
      rslt += ", #{format_size(stats[:bytes_sent])} sent"
      rslt += ", #{format_size(stats[:bytes_rcvd])} rcvd"
      rslt += ", #{stats[:failures]} failures"
      rslt += ", #{stats[:inflight]} inflight"
      rslt += ", %u recent ops/s" % stats[:recent_ops_per_sec]
      rslt
    end

    def update_ops_per_sec
      @prev_stats ||= @stats.dup
      @prev_time ||= Time.now

      elapsed = Time.now - @prev_time
      requests = @stats[:requests] - @prev_stats[:requests]

      @stats[:recent_ops_per_sec] = requests / elapsed
      @prev_time = Time.now
      @prev_stats = @stats.dup
    end

    def finished?
      Time.now > @end_time or @stop_test
    end

    def next_request(user_count)
      if finished?
        signal_done if @stats[:inflight] == 0
      else
        @mutex.synchronize {
          think_time = STAC::SeedManager.get_random("mix_#{@mix.count}_#{user_count}") % @pause_sec if @pause_sec != 0
          think_time = 1 if think_time < 1 # Think time should be larger than 1
          EM.add_timer(think_time) { issue_request(@mix.next, user_count) }
          @logger.info("      User #{user_count} in thinking for #{think_time}s")
        }
      end
    end

    def issue_request(req, user_count)
      # Start the timer and execute the given action
      start_time = Time.now
      @stats[:inflight] += 1
      
      url  = req.url
      verb = req.verb
      body = req.body
      @logger.info("   [%04u]>>User #{user_count} http request #{url} \{:ver=>#{verb} :body=>#{body}\}" % (Time.now - @start_time) )
      http = EM::HttpRequest.new(url).send(verb, {:body => body})

      http.errback {
        elapsed = Time.now - start_time
        @stats[:inflight] -= 1
        unless finished?
          @logger.error("      User #{user_count} HTTP connection error for #{verb} #{url} #{elapsed}s")
          @stats[:requests]    += 1
          @stats[:failures]    += 1
          @stats[:total_time]  += elapsed
        end
        next_request(user_count)
      }

      http.callback {
        elapsed = Time.now - start_time
        @stats[:inflight] -= 1
        unless finished?
          level = http.response_header.status >= 400 ? :error : :debug
          @logger.send(level, "      User #{user_count} HTTP status #{http.response_header.status} for #{verb} #{url} #{elapsed}s")
          @stats[:requests]    += 1
          @stats[:failures]    += 1 if http.response_header.status >= 400
          @stats[:bytes_sent]  += req.body.length if req.body
          @stats[:bytes_rcvd]  += http.response.length
          @stats[:total_time]  += elapsed
        end
        next_request(user_count)
      }
    end

    def sanitize_base_url(base_url)
      # Make sure the URL starts with HTTP - we don't do anything else
      base_url = "http://" + base_url unless base_url[0..7] == "http://"

      # Strip a trailing "/" if present
      base_url[-2,1] = "" if base_url[-2,1] == "/"
      base_url
    end

    def calculate_end_time(duration)
      # duration may come through as Infinity
      duration == 1/0.0 ? duration = 999999 : duration
      end_time = Time.now + duration
    end

    def sanitize_usr_rate(usr_rate)
      # The use rate better be positive
      # (and these are ops/s, so default to light usage)
      usr_rate = 1 if not usr_rate or usr_rate <= 0
      usr_rate
    end

    def sanitize_pause_ms(pause_ms)
      pause_ms ||= 0.0
    end

    def generate_mix(base_url, user_actions)
      if user_actions.length == 1
        user_action = user_actions[0]
        return StaticMix.new(base_url, user_action, user_action.url)
      elsif user_actions.length > 1
        return RandomMix.new(base_url, user_actions)
      else
        raise "A use action must have one :action or a :mix array"
      end
    end

    def self.adjust_maxfd(limit)
      maxfd = Process.getrlimit(Process::RLIMIT_NOFILE)[0]
      if limit > maxfd
        Process.setrlimit(Process::RLIMIT_NOFILE, limit)
      end
    end

    def run_new(base_url, user_actions, http_ms_pause, http_duration, http_load, start_time)
      base_url    = sanitize_base_url(base_url)
      @mix        = generate_mix(base_url, user_actions)
      @pause_sec  = sanitize_pause_ms(http_ms_pause)
      @end_time   = calculate_end_time(http_duration)
      usr_rate    = sanitize_usr_rate(http_load)
      @start_time = start_time

      timer = EM.add_periodic_timer(3) {
        update_ops_per_sec
        timer.cancel if finished?
      }

      usr_count = 1
      usr_rate.times { next_request(usr_count); usr_count += 1 }
    end

    def run(opts)
      base_url    = sanitize_base_url(opts[:app_url])
      @mix        = generate_mix(base_url, opts)
      @pause_sec  = sanitize_pause_ms(opts[:http_ms_pause])
      @end_time   = calculate_end_time(opts[:http_duration])
      usr_rate    = sanitize_usr_rate(opts[:http_load])

      timer = EM.add_periodic_timer(3) {
        update_ops_per_sec
        timer.cancel if finished?
      }

      usr_rate.times { next_request }
    end

    def stop
      @stop_test = true
    end

    def stats_string
      LoadGenerator::format_stats(@stats)
    end

    def signal_done
      @mutex.synchronize {
        @stopped = true
        @stopped_cv.signal
      }
    end

    def wait_for_completion
      @mutex.synchronize {
        while @stopped == false
          @stopped_cv.wait(@mutex)
        end
      }
    end

  end

  # The StacLoadGenerator has to deal with some odd concurency issues.
  # The main stac driver is going to call StacLoadGenerator.new just
  # once.  After that, stac will make multiple calls to run in different
  # threads.  Given that we are using EM, we need to coordinate the
  # startup and shutdown of EM.  We will spin up EM in a seperate
  # thread if it isn't already running.  Similarly, we shut down
  # EM when the last run() is finished.  (We can restart it again
  # if needed).
  #
  # stac may eventually use EM, so that this trickery is unecessary,
  # but it doesn't now.  Don't be fooled by the fact that stac is trying
  # to configure EM, or that stac is a sinatra app.  EM isn't running
  # when the run() method below is called.
  #
  # FIXME: the handling of stats across instances has become
  # pretty much of a total hack.  Clean it up.

  class StacLoadGenerator
    MAX_FD = 4096

    def initialize(logger)
      @logger = logger
      @tests = {}
      @stats = {}
      @lock  = Mutex.new
      @load  = 0
      @em_running = false
      @em_cv      = ConditionVariable.new

      @stats_from_finished_load = {}
    end
    
    def run_new(base_url, user_actions, http_ms_pause, http_duration, http_load, start_time)
      load_gen = LoadGenerator.new(@logger)
      @start_time = start_time

      begin
        max_fd = Process.getrlimit(Process::RLIMIT_NOFILE)[0]
      rescue => e
        # let's be pretty conservative
        max_fd = 1024
        @logger.warn("unable to get maxfd, assuming #{max_fd}")
      end

      @lock.synchronize {
        new_load = @load + http_load
        # make sure to leave some overhead for stdin/out/err + other
        # fds that ruby or the system might have open (logs, pipes, etc)
        if new_load > max_fd - 20
          puts "ERROR: combined http_load conncurrency is too high -- ignoring 'use' request"
          return
        end

        start_em_thread if @tests.empty?
        @tests[load_gen.object_id] = load_gen
        while not @em_running
          @em_cv.wait(@lock)
        end
      }

      load_gen.run_new(base_url, user_actions, http_ms_pause, http_duration, http_load, start_time)
      load_gen.wait_for_completion

      @lock.synchronize {
        load_gen.stats.each { |k, v| @stats_from_finished_load[k] = v + (@stats_from_finished_load[k] || 0) }
        @stats_from_finished_load.delete(:recent_ops_per_sec)
        @stats_from_finished_load.delete(:inflight)
        @tests.delete(load_gen.object_id)
        stop_em_thread if @tests.empty?
      }
    end

    def run(opts)
      load_gen = LoadGenerator.new(@logger)

      begin
        max_fd = Process.getrlimit(Process::RLIMIT_NOFILE)[0]
      rescue => e
        # let's be pretty conservative
        max_fd = 1024
        @logger.warn("unable to get maxfd, assuming #{max_fd}")
      end

      @lock.synchronize {
        new_load = @load + opts[:http_load]
        # make sure to leave some overhead for stdin/out/err + other
        # fds that ruby or the system might have open (logs, pipes, etc)
        if new_load > max_fd - 20
          puts "ERROR: combined http_load conncurrency is too high -- ignoring 'use' request"
          return
        end

        start_em_thread if @tests.empty?
        @tests[load_gen.object_id] = load_gen
        while not @em_running
          @em_cv.wait(@lock)
        end
      }

      load_gen.run(opts)
      load_gen.wait_for_completion

      @lock.synchronize {
        load_gen.stats.each { |k, v| @stats_from_finished_load[k] = v + (@stats_from_finished_load[k] || 0) }
        @stats_from_finished_load.delete(:recent_ops_per_sec)
        @stats_from_finished_load.delete(:inflight)
        @tests.delete(load_gen.object_id)
        stop_em_thread if @tests.empty?
      }
    end

    def start_em_thread
      # Note, while we could bump the maxfd on every call to run()
      # and keep adding to the maxfd as needed, I'm concerned that
      # EM will handle that correctly and that it hasn't allocated
      # any static data structures or cached the maxfd value at the
      # time that EM.run is called.  We also can't go *too* high
      # as a default, e.g. 64K, or we run the risk of being denied
      # permissions due to quota issues.
      HttpLoad::LoadGenerator.adjust_maxfd(MAX_FD) if RUBY_PLATFORM =~ /darwin/

      Thread.new do
        EM.run {
          EM.add_periodic_timer(5) { update_stats }
          @lock.synchronize {
            @em_running = true
            @em_cv.signal
          }
        }

        @lock.synchronize {
          @em_running = false
          @em_cv.signal
        }
      end
    end

    def stop_em_thread
      EM.stop
    end

    def update_stats
      stats = {}
      @lock.synchronize {
        @tests.values.each { |t| t.stats.each { |k, v| stats[k] = v + (stats[k] || 0) }}
        @stats = stats
      }
    end

    def abort_test
      @lock.synchronize { @tests.values.each { |t| t.stop } }
    end

    def stop_test
      @lock.synchronize { @tests.values.each { |t| t.stop } }
    end

    def get_total_requests
      @lock.synchronize { @stats[:requests] || 0 }
    end

    def get_totals
      @lock.synchronize {
        stats = @stats.dup
        @stats_from_finished_load.each { |k, v| stats[k] = v + (@stats_from_finished_load[k] || 0) }
        if stats.empty?
          ""
        else
          LoadGenerator::format_stats(stats)
        end
      }
    end
  end

end

if __FILE__ == $0
  if ARGV[0].nil?
    puts "usage: #{$0} <stac-app-url>"
    exit
  end

  logger       = Logger.new(STDERR)
  logger.level = Logger::INFO

  HttpLoad::LoadGenerator.adjust_maxfd(4096) if RUBY_PLATFORM =~ /darwin/
  hl = HttpLoad::LoadGenerator.new(logger)
  opts = {
    :app_url       => ARGV[0],
    :duration      => 300,
    :http_load     => 256,
    :http_ms_pause => 0,
    :mix => [
      {
        :fraction   => 30,
        :action     => :http_get,
        :url        => "/"
      },
      {
        :fraction   => 40,
        :action     => :http_get,
        :url        => "/data/[VALUE]",
        :rndval_min =>  16,
        :rndval_max =>  32
      },
      {
        :fraction   => 30,
        :action     => :http_put,
        :url        => "/data",
        :rnddsz_min =>  16,
        :rnddsz_max =>  32 },
    ]
  }

  ["TERM", "INT"].each { |sig| trap(sig) { hl.stop; EM.stop } }

  EM.run do
    timer = EM.add_periodic_timer(10) {
      puts hl.stats_string
      EM.stop if hl.finished?
      timer.cancel if hl.finished?
    }
    hl.run(opts)
  end

  hl.update_ops_per_sec
  puts hl.stats_string
end

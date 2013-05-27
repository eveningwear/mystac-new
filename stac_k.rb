#!/usr/bin/env ruby
require 'rubygems'
require 'erb'
require 'yaml'
require 'logger'
require 'thin'
require 'sinatra/base'
require 'optparse'
require 'fileutils'
require 'nats/client'
require 'net/http'
require 'algorithms'
require 'pp'
require 'vmc'

require './http_load'
require './vmc_base'

AC_HOMEDIR = FileUtils.pwd

INFINITY = 1/0.0

$verbose = false
$bequiet = false
$newgen  = false
$xdetail = false

# Ludicrous hack to add String::match(regexp, pos) for earlier versions of Ruby
begin
  "foo".match(/f../, 0)
rescue ArgumentError
  class String
    alias :oldmatch :match
    def match(rx, pos=nil)
      if not pos or pos == 0
        return oldmatch(rx)
      else
        return self[pos..-1].oldmatch(rx)
      end
    end
  end
end

module STAC
  class Error < StandardError; end

  class AppResponseError < Error
    def initialize(msg, response, app, user)
      @msg      = msg
      @response = response
      @app      = app
      @user     = user
    end

    def to_s
      "#{@msg} app: '#{@app}' user: '#{@user}' status: #{@response.status}"
    end
  end

  class AppInfoError < AppResponseError
    def initialize(*args)
      super("Could not get info", *args)
    end
  end

  class AppLogError < AppResponseError
    def initialize(response, app, user)
      super("Could not get log", *args)
    end
  end

  class AppCrashLogError < AppResponseError
    def initialize(*args)
      super("Could not get crash log", *args)
    end
  end

  class AppCrashesError < AppResponseError
    def initialize(*args)
      super("Could not get crashes", *args)
    end
  end

  class VMC_Actions
    # The following actions map directly onto AC commands
    VMC_ADD_USER  =  1
    VMC_DEL_USER  =  2
    VMC_PUSH_APP  =  3
    VMC_DEL_APP   =  4
    VMC_UPD_APP   =  5
    VMC_INSTCNT   =  6
    VMC_CRASHES   =  7
    VMC_CRSLOGS   =  8
    VMC_APPLOGS   =  9
    VMC_ADD_SVC   = 10
    VMC_DEL_SVC   = 11

    # The following are pseudo-actions (more complex that one AC command)
    VMC_CHK_APP   = 50

    def self.action_to_s(act)
      case act
      when VMC_ADD_USER then return "register"
      when VMC_DEL_USER then return "unregister"
      when VMC_PUSH_APP then return "push"
      when VMC_DEL_APP  then return "delete"
      when VMC_UPD_APP  then return "update"
      when VMC_INSTCNT  then return "instances"
      when VMC_CRASHES  then return "crashes"
      when VMC_CRSLOGS  then return "crashlogs"
      when VMC_APPLOGS  then return "logs"
      when VMC_ADD_SVC  then return "bind-service"
      when VMC_DEL_SVC  then return "unbind-service"
      when VMC_CHK_APP  then return "-check-app-"
      else                   return "unknown#{act}"
      end
    end
  end

  ARG_SUB_PREFIX = "__STAC_ARG_"    # marks arg substitutions

  SCN_REF_PREFIX = "USE_SCN_"       # scenarios are referenced via this string

  $app_defs = {}
  $dev_defs = {}
  $use_defs = {}
  $scn_defs = {}
  $mix_defs = {}
  $inf_defs = {}

  # Takes an ActionQueue and splits it into seperate queues per context
  # (which need to be serialized) and keeps them ordered in a priority
  # queue based on the synthetic clock time that they are supposed
  # to run at.  The action queue that is passed in is already sorted
  # by the :clock time.
  class PriorityContextQueue
    def initialize(logger, action_queue)
      @logger = logger
      @lock   = Mutex.new
      @priority_queue = Containers::PriorityQueue.new

      @lock.synchronize {
        context_queues = {}
        action_queue.each do |a|
          context_queue = context_queues[a[:context][0]] ||= []
          context_queue << a
        end

        context_queues.values.each do |q|
          @logger.debug("PriorityQueue pushing context #{q[0][:context][0]}")
          @priority_queue.push(q, -q[0][:clock])
        end
        @logger.info("PriorityQueue created #{context_queues.length} context queues")
      }
    end

    # returns a context_queue.  the caller has to push it back in
    # when they are done with it
    def pop
      context_queue = @lock.synchronize { @priority_queue.pop }
      @logger.debug("PriorityQueue thread #{Thread.current.object_id} popped context #{context_queue[0][:context][0]}") if context_queue
      context_queue
    end

    # pushes a context_queue back into the priority queue
    def push(context_queue)
      # use a negative clock value as bigger numbers have higher priority
      @logger.debug("PriorityQueue thread #{Thread.current.object_id} pushing context #{context_queue[0][:context][0]}")
      @lock.synchronize { @priority_queue.push(context_queue, -context_queue[0][:clock]) }
    end

    def length
      @lock.synchronize { @priority_queue.length }
    end
  end

  # The following class executes a test plan (i.e. a series of "vmc"
  # and "user" actions).
  class StressTestExec < VMC::BaseClient

    def initialize(config, logger, target)
      @config  = config
      @logger  = logger
      @target  = target

      # Create and initialize the HTTP use generator
      @use_runner = HttpLoad::StacLoadGenerator.new(logger) unless @config['no_http_uses']

      # Make sure we delete any users/apps/etc. we create before exiting
      @cleanup      = []
      @cleanup_acts = 0
      @cleanup_lock = Mutex.new

      # This lock protects the peak instance count
      @instcnt_lock = Mutex.new

      # Lock for pulling things from the action queue
      @queue_lock   = Mutex.new

      # Lock for recording "dev" execution stats (such as time elapsed)
      @stats_lock   = Mutex.new

      # Initialize a few other instance variables
      @stop_run_now  = false
      @test_run_done = false
      @doing_cleanup = false

      # Initialize the dev/use action counts and lock
      @use_act_count = 0
      @dev_act_count = 0
      @dev_act_done  = 0
      @dev_act_aborted = 0
      @lck_act_count = Mutex.new

      # Not executing any commands yet, no instances yet, etc.
      @cur_dev_cmds  = nil
      @cur_instances = 0
      @max_instances = 0
    end

    def adj_overall_instcnt(diff)
      @instcnt_lock.synchronize do
        @cur_instances += diff
        @max_instances = @cur_instances if @max_instances < @cur_instances
      end
    end

    def rec_dev_action_result_norm(failed, time_beg, time_end = Time.now)
      @stats_lock.synchronize do
        if failed
          @dev_act_fails += 1
        else
          @dev_act_cnt_n += 1
          @dev_act_nrmtm += time_end - time_beg
##########if time_end - time_beg > 0.4 ; puts "Dev action took %5.2f seconds:" % (time_end - time_beg) ; caller.each { |s| puts "  " + s } ; end
        end
      end
    end

    def rec_dev_action_result_slow(failed, time_beg, time_end = Time.now)
      @stats_lock.synchronize do
        if failed
          @dev_act_fails += 1
        else
          @dev_act_cnt_s += 1
          @dev_act_slwtm += time_end - time_beg
        end
      end
    end

    def display(msg, nl=true)
      if nl
        puts(msg)
      else
        print(msg)
        STDOUT.flush
      end
    end

    def fatal_error(msg)
      @logger.error(msg)
      STDERR.puts(msg)
      abort_test
      exit 1
    end

    def internal_error(msg)
      msg = "INTERNAL STAC ERROR: " + msg
      @logger.error(msg)
      STDERR.puts(msg)
      exit 1
    end

    def slumber(tim)
      while tim > 0
        sleep(tim < 0.5 ? tim : 0.5)
        return false if @test_run_done or @stop_run_now
        tim -= 0.5
      end
      true
    end

    def auth_hdr(user)
      auth = { 'AUTHORIZATION' => "#{@admin_token}" }
      auth['PROXY-USER'] = user if user
      auth
    end

    def log_avg_info(uselog, str)
      if uselog then @logger.info(str) else puts str end
    end

    def report_averages(uselog, prefix="")
      return if @config['dry_run_plan']
      return if @test_run_done and prefix == ""

      marker = ""
      marker = @config['unique_stacid'] if @config['unique_stacid'] and not uselog

      total_dev_actions = @dev_act_done + @dev_act_count
      log_avg_info(uselog, "#{marker}#{prefix}#{100 * @dev_act_done / total_dev_actions}% dev defs complete (#{@dev_act_done} of #{total_dev_actions} with #{@dev_act_aborted} aborted)")

      inst = (prefix == "") ? @max_instances : @cur_instances
      log_avg_info(uselog, "#{marker}#{prefix}Approximate total app instance count: #{inst}") if inst > 0

      log_avg_info(uselog, "#{marker}#{prefix}Total number of 'dev' actions issued: #{@dev_act_cnt_n + @dev_act_cnt_s + @dev_act_fails}")
      log_avg_info(uselog, "#{marker}#{prefix}Total number of 'dev' actions failed: #{@dev_act_fails}") if @dev_act_fails > 0 or prefix == ""

      # Display average time per dev action (if we've had successes)
      if @dev_act_cnt_n > 0
        log_avg_info(uselog, "#{marker}#{prefix}Average time of 'dev' action / normal: %5.2f sec" % (@dev_act_nrmtm/@dev_act_cnt_n))
      end
      if @dev_act_cnt_s > 0
        log_avg_info(uselog, "#{marker}#{prefix}Average time of 'dev' action /  slow : %5.2f sec" % (@dev_act_slwtm/@dev_act_cnt_s))
      end

      log_avg_info(uselog, "#{marker}#{prefix}#{@use_runner.get_totals}") if @use_runner and (@use_runner.get_total_requests > 0 or prefix == "")
    end

    # Check the response for an error; return true if OK, log the error and
    # return false otherwise. Optionally also record a "dev" action result
    # and time (when 'beg_time' is not false).

    def handle_response(response, beg_time = nil)

if $newgen and response.kind_of? Array
  puts "UNDONE: handle response from newgen API call -- #{response.inspect} !!!!!!!!!!"
  exit!
end

      # If no response or the response looks OK, things are happy
      if (response and response.status < 400)
        rec_dev_action_result_norm(false, beg_time) if beg_time
        return true
      end

      # Something went wrong - log the failure if beg_time given
      rec_dev_action_result_norm(true, beg_time, Time.now) if beg_time

      # Try to log a decent error message
      if not response.content or response.content == ""
        @logger.error("Unknown error in response from server (status=#{response.status})")
      else
        begin
          error_json = JSON.parse(response.content)
          @logger.error(error_json['description'].to_s)
        rescue
          response.content ||= "System error has occurred."
          @logger.error(response.content.to_s)
        end
      end

      # Let the caller know that things didn't go too well
      false
    end

    def action_to_s(a)
      act = a[:action]
      # The action type should be use or dev
      return "Use #{act}"                          if a[:act_type].kind_of? STAC::TestDef_Use
      return "Dev #{VMC_Actions.action_to_s(act)}" if a[:act_type].kind_of? STAC::TestDef_Dev
      # This is very suspicious
      "[unknown #{act} of type #{a[:act_type].class}]"
    end

    # Given an application name (and user) returns the instance count from AC;
    #
    # if all goes well we return the following triple:
    #   [ total_instances , running_instances , crashed_instances ]
    #
    # If we can't get the instance counts from AC, we return [0,0,0].
    def app_instance_count(app, user, client)
      # Instance counts: tcnt=total, rcnt=running, ccnt=crashed
      rcnt = tcnt = ccnt = 0

      # ISSUE: should we record the timing for this CC call?
      if $newgen
        begin
          inst = client.app_instances(app)
          # Empty array means no instances at all
          return 0,0,0 if inst.is_a? Array
        rescue => e
          @logger.warn("Request for instances of app #{app} failed: #{e.inspect}")
          return 0,0,0
        end
      else
        inst = get_app_instances_internal(@droplets_uri, app, auth_hdr(user))
      end

      # Make sure the resulting app info has instance info
      if $newgen
        inst = inst[:instances ] if inst
      else
        inst = inst["instances"] if inst
      end
      return 0,0,0 unless inst

      # Count the total and running instances
      if $newgen
        inst.each { |i| tcnt += 1; rcnt += 1 if i[:state ] == "RUNNING" }
      else
        inst.each { |i| tcnt += 1; rcnt += 1 if i["state"] == "RUNNING" }
      end

      # Are there any crashed instances?
      crsh = get_app_crashes(app, user, client)
      ccnt = crsh.length if crsh and crsh.length > 0

      return [tcnt, rcnt, ccnt]
    end

    def get_app_info(app, user, client)
      # ISSUE: should we record the timing for this CC call?
      if $newgen
        begin
          return client.app_info(app)
        rescue => e
          @logger.error("Could not get info for app #{app}: #{e.inspect}")
          return nil
        end
      else
        response = get_app_internal(@droplets_uri, app, auth_hdr(user))
        if response.status != 200
          raise AppInfoError.new(response, app, user)
        end
        JSON.parse(response.content)
      end
    end

    def log_crash_detail(app, user, client, last)
      crsh = get_app_crashes(app, user, client)

      # Look for any new crashed instances
      index = 0
      crsh.each do |c|
        iid = c['instance']
        its = c['since']
        if not last.index(iid)
          @logger.warn("App #{app} has new crashed instance #{iid}")
          grab_crash_logs(app, user, client, index, true)
        end
        index += 1
      end

      # Return the current (updated) list of crashed instances to the caller
      return crsh.collect { |c| c['instance'] }
    end

    # Change the instance count of the given app; the desired new number of
    # instances (passesd in 'inst') may be lower or higher compared to the
    # current instance count. We return the new count of running instances,
    # which could be lower than the desired count if we run out of time.
    #
    # The 'ainf' argument references the "app info" descriptor that is used
    # in the execution loop to keep track of apps (see the code that handles
    # the VMC_PUSH_APP action in execute_plan() for an example of its use).
    #
    # Note that when ainf[:inst_total] is zero, this means that we just did
    # an initial push of an app (and thus its current instance count should
    # be considered to be zero, even if AC already knows about some of the
    # instances).

    def set_instance_count(app, user, client, inst, starting, ainf)
      # Get hold of the current instance count
      cnts = app_instance_count(app, user, client)
      bcnt = cnts[0]          # total   count
      init = cnts[1]          # running count
      crsh = cnts[2]          # crashed count

      # If we're starting a new app, count all instances as new
      bcnt = 0 unless ainf[:inst_total] > 0

      # Keep track of how long this entire thing takes
      beg_time = Time.now

      # We haven't logged any crash information yet
      llog = []

      # ISSUE: what is a reasonable length of time to wait for this?
      # For now we use the following formula:
      #
      #    initial app push/start: wait up to 60 seconds
      #
      #    increase in instance count: wait up to 30 + <inst-cnt-diff> * 2 seconds
      #
      #    decrease in instance count: wait up to 30 seconds

      diff = inst - init
      secs = ((diff > 0) ? diff * 2 : 0) + (starting ? 60 : 30)

      # Let's cap the wait time at a max. of 60 seconds
      secs = 60 if secs > 60

      # Report crashed instances only once
      repcrsh = false

      # Wait for the right number of instances to be running
      while secs > 0
        # Get the current number of instances
        cnts = app_instance_count(app, user, client)

        # Update the instance count info for the app
        ainf[:inst_total  ] = cnts[0]
        ainf[:inst_running] = cnts[1]
        ainf[:inst_crashed] = cnts[2]

        # Done if we've reached the desired instance count (or test is ending)
        break if cnts[1] >= inst or @stop_run_now

        # Check for crashes
        if cnts[2] > 0
          if cnts[2] != repcrsh
            @logger.warn("We have #{cnts[2]} crashed instances of #{app} with crash mode \'#{ainf[:crash_info]}\'")
            repcrsh = cnts[2]
          end
          llog = log_crash_detail(app, user, client, llog) if $xdetail
        end

        # Tell AC to give us the number of instances we desire
        info = get_app_info(app, user, client)
        info['instances'] = inst
        if $newgen
          client.update_app(app, info)
        else
          response = update_app_state_internal(@droplets_uri, app, info, auth_hdr(user))
          handle_response(response)
        end

########puts "Waiting for app instances: have #{cnts[1]} but need #{inst}"

        # Wait a bit, up to the chosen time limit
        secs -= 0.5 ; sleep 0.5
      end

      # Keep the peak instance count updated
      adj_overall_instcnt(ainf[:inst_total] - bcnt)

      # Either we've reached the desired instance count or time has run out
      have = ainf[:inst_running]
      if have == inst or @stop_run_now
        # If the test is being stopped, let's just quietly end things
        rec_dev_action_result_slow(false, beg_time)
      else
        # Failed to achieve the desired instance count
        rec_dev_action_result_slow(true,  beg_time)
        @logger.error("After a long wait we only have #{have} instances of #{app} instead of #{inst}")
      end

      # We always return the current running instance count as the result
      have
    end

    # Copied from vmc
    def log_file_paths
      %w[logs/stderr.log logs/stdout.log logs/startup.log]
    end

    # Retrieve logs for a given instance of a running AC app
    def grab_app_logs(app, user, client, inst)
      if not inst.kind_of? Fixnum
        internal_error("grab_app_logs() called with instance #{inst} of type #{inst.class}; expecting Fixnum")
      end
      log_file_paths.each do |path|
        beg_time = Time.now
        if $newgen
          begin
            client.app_files(app, path, inst)
            rec_dev_action_result_norm(false, beg_time)
          rescue => e
            rec_dev_action_result_norm(true,  beg_time)
            @logger.error("Could not get log for app #{app}")
          end
        else
          response = get_app_files_internal(@droplets_uri, app, inst, path, auth_hdr(user))
          if response.status != 200
            rec_dev_action_result_norm(false, beg_time)
            raise AppLogError.new(response, app, user)
          elsif not response.content.empty?
            rec_dev_action_result_norm(true,  beg_time)
          end
        end
      end
    end

    def grab_crash_logs(app, user, client, inst, logit = false)
      if not inst.kind_of? Fixnum
        internal_error("grab_crash_logs() called with instance #{inst} of type #{inst.class}; expecting Fixnum")
      end
      ['/logs/err.log', '/logs/staging.log', 'logs/stderr.log', 'logs/stdout.log', 'logs/startup.log'].each do |path|
        beg_time = Time.now
        if $newgen
          begin
            client.app_files(app, path, inst)
            rec_dev_action_result_norm(false, beg_time)
          rescue => e
            rec_dev_action_result_norm(true,  beg_time)
            @logger.error("Could not get crash log for app #{app}")
          end
        else
          response = get_app_files_internal(@droplets_uri, app, inst, path, auth_hdr(user))
          if response.status != 200
            rec_dev_action_result_norm(true,  beg_time)
            if response.status == 400 or response.status == 500
              # ISSUE: how do we know when this is OK vs. failure?
              @logger.info("Response from get_crash_logs(#{path}): #{response.status}")
            else
              raise AppCrashLogError.new(response, app, user)
            end
          else
            rec_dev_action_result_norm(false, beg_time)
            if logit
              @logger.info("Crash log #{path} for app #{app}: #{response.content}")
            end
            if not response.content.empty?
            end
          end
        end
      end
    end

    def get_app_crashes(app, user, client)
      beg_time = Time.now
      if $newgen
        client.app_crashes(app)
      else
        response = get_app_crashes_internal(@droplets_uri, app, auth_hdr(user))
        if response.status == 200
          rec_dev_action_result_norm(false, beg_time)
        else
          rec_dev_action_result_norm(true,  beg_time)
          raise AppCrashesError.new(response, app, user)
        end
        JSON.parse(response.content)['crashes']
      end
    rescue => e
      @logger.error("get_app_crashes error #{e.inspect}")
      raise e
    end

    def eval_exec_arg(arg, app, user)
      return arg unless arg
      arg = arg.to_s unless arg.kind_of? String
      vpos = 0
      sbst = false
      while fpos = arg.index("&", vpos)
        if arg[fpos+1, 14] == "instance_count"
          # Extract the app name
          mtch = arg.match(/\s*\([\:\s*](\w+)\s*\)/, fpos + 15)
          if mtch
            # Replace the reference with the actual instance count
            cnt = app_instance_count(mtch[1], user)
            if cnt[1]
              arg[fpos, 15 + mtch.to_s.length] = cnt[1].to_s
              sbst = true
            end
          end
        end
        vpos = fpos + 1
      end
      arg = eval(arg).to_s if sbst
      arg
    end

    def mem_in_MB(val)
      return val[0 .. -2].to_i        if val[-1,1] == 'M'
      return val[0 .. -2].to_i * 1024 if val[-1,1] == 'G'
      val.to_i
    end

    # Invent a unique name for the service
    def invent_service_name(app, user, type, vend, pref_only = false)
      amps = user.index("@")
      user = amps ? user[0,amps-1] : user
      name = "svc_#{name}_#{app}_#{type}_#{vend}_"
      return name + (pref_only ? "" : fast_uuid[0..6])
    end

    def find_matching_service(app, user, client, stab, desc)
      base = invent_service_name(app, user, desc[:svc_type], desc[:svc_vendor], true)
      stab.each { |s| return s if s[0,base.length] == base }
      nil
    end

    def add_app_service(app, user, client, svc)
      # Get hold of the various service attributes
      s_type = svc[:type   ]
      s_vend = svc[:vendor ]
      s_vers = svc[:version]
      s_tier = svc[:tier   ]
      s_opts = svc[:options]
      s_desc = svc[:desc   ] # for NG client

      # Invent a unique name for the service
      name = invent_service_name(app, user, s_type, s_vend)

      info =
      {
        :name    => name,
        :type    => s_type,
        :vendor  => s_vend,
        :tier    => s_tier,
        :version => s_vers,
        :options => s_opts
      }

      # Provision the service for the user
      beg_time = Time.now
      if $newgen
        begin
          client.create_service(s_desc, name)   # horrible - FIXME!!!!!!
          rec_dev_action_result_norm(false, beg_time)
        rescue => e
          rec_dev_action_result_norm(true , beg_time)
          @logger.error("Could not create service for app #{app}: #{e.inspect}")
          return false
        end
      else
        response = add_service_internal(@services_uri, info, auth_hdr(user))
        handle_response(response, beg_time)
      end

      # Now add the service to the application's list of services
      info = get_app_info(app, user, client)
      psvc = info['services'] ? info['services'] : []
      psvc << name
      info['services'] = psvc

      beg_time = Time.now
      if $newgen
        begin
          client.bind_service(name, app)
          rec_dev_action_result_norm(false, beg_time)
        rescue => e
          rec_dev_action_result_norm(true , beg_time)
          @logger.error("Could not bind service #{name} to app #{app}: #{e.inspect}")
          return false
        end
      else
        response = update_app_state_internal(@droplets_uri, app, info, auth_hdr(user))
        handle_response(response, beg_time)
      end

      @logger.debug("Provisioned service #{name} for app #{app}")
      true
    end

    def pack_app_bits(dir, zipfile) # copied from zip_util.rb / pack()
      exclude = ['..', '.', '*~', '#*#', '*.log', 'app.zip']
      excludes = exclude.map { |e| "\\#{e}" }
      excludes = excludes.join(' ')
      if RUBY_PLATFORM !~ /mingw/
        return if system("cd #{dir} ; zip -q -r -x #{excludes} #{zipfile} . 2> /dev/null")
      end
      # Do Ruby version if told to or native version failed
      Zip::ZipFile::open(zipfile, true) do |zf|
        Dir.glob("#{dir}/**/*", File::FNM_DOTMATCH).each do |f|
          process = true
          exclude.each { |e| process = false if File.fnmatch(e, File.basename(f)) }
          zf.add(f.sub("#{dir}/",''), f) if (process && File.exists?(f))
        end
      end
    end

    def push_app_bits(app, user, client, is_update, path, svcs=nil, war=nil, hasdb=nil)
      begin
        # Push the app bits - this might take a while
        beg_time = Time.now

        begin
          war = File.expand_path(war, path) if war
          if $newgen
            # Is there an archive already?
            upload_file = File.join(path, "app.zip")
            if not File.exists?(upload_file)
              # Choose unique / temporary name(s) for the upload
####          upload_dir  = "#{Dir.tmpdir}/_stac_#{app}_files"
####          FileUtils.rm_rf(upload_dir)
              upload_file = "#{Dir.tmpdir}/_stac_#{app}.zip"
              FileUtils.rm_f(upload_file)

              # Create the archive for the upload
              pack_app_bits(path, upload_file)
            end

            # Ready to upload the app bits
            client.upload_app(app, upload_file, nil)
          else
            upload_app_bits(path,
                            @resources_uri,
                            @droplets_uri,
                            app,
                            auth_hdr(user),
                            war,
                            hasdb)
          end
        rescue => e
          @logger.error("Could not push application bits: #{e.inspect}\n#{e.backtrace.join("\n")}")
          return false
        end

        # Record the result / time of the 'upload' action
        rec_dev_action_result_slow(false, beg_time)

        # Do we need to provision any services for the app?
        if svcs
          svcs.each { |s| add_app_service(app, user, client, s) }
        end

        # Is the app running?
        info = get_app_info(app, user, client)
        if info['state'] == 'STARTED' or info[:state] == 'STARTED'
          # We're done unless we're doing an app update
          return true unless is_update

          # Stop the app, then start it again with the new bits
          if $newgen
            info[:state] = 'STOPPED'
            begin
              client.update_app(app, info)
            rescue => e
              @logger.error("Could not change app state to STOPPED: #{e.inspect}")
              return true
            end
          else
            info['state'] = 'STOPPED'
            response = update_app_state_internal(@droplets_uri, app, info, auth_hdr(user))
            handle_response(response, beg_time)
          end
        end

        # App is not running, ask to make it so
        if $newgen
          info[:state ] = 'STARTED'
        else
          info['state'] = 'STARTED'
        end

        beg_time = Time.now
        if $newgen
          begin
            client.update_app(app, info)
          rescue => e
            @logger.error("Could not change app state to RUNNING: #{e.inspect}")
          end
        else
          response = update_app_state_internal(@droplets_uri, app, info, auth_hdr(user))
          handle_response(response, beg_time)
        end
      end
      true
    end

    def ctx_mark(user, scen)
      ("u%04u,s" % user) + (scen ? ("%02u" % scen) : "**")
    end

    def do_use_action(user, scen, act, arg, harg, clk, dry_run)
      if act == :http_mix
        use = "mix[#{arg[:mix].length}]"
      else
        use = act.to_s
        arg[:action] = act
      end
      add = harg ? " and #{harg.inspect}" : ""
      @logger.info("[%04u]>>use \{#{ctx_mark(user,scen)}\} #{use} #{arg.inspect}#{add}" % clk)
      @use_runner.run(arg) unless @config['no_http_uses'] or dry_run
    end

    def delete_app(app, user, client)
      adj_overall_instcnt(-app_instance_count(app, user, client)[0])
      info = get_app_info(app, user, client)
      psvc = info['services']
      if psvc
        psvc.each do |s|
          # Delete the service from the user
          @logger.debug("Removing service #{s} of user #{user}")
          # ISSUE: should we include this in the overall "dev" timing results?
          beg_time = Time.now
          if $newgen
            internal_error("Thing at line #{__LINE__} not yet implemented for -n / newgen")
          else
            remove_service_internal(@services_uri, s, auth_hdr(user))
          end
          rec_dev_action_result_norm(false, beg_time)
        end
      end
      @logger.debug("Deleting app #{app}")
      beg_time = Time.now
      if $newgen
        internal_error("Thing at line #{__LINE__} not yet implemented for -n / newgen")
      else
        delete_app_internal(@droplets_uri, @services_uri, app, info['services'], auth_hdr(user))
      end
      rec_dev_action_result_norm(false, beg_time)
    end

    def delete_user(user)
      @logger.debug("Deleting user #{user}")
      beg_time = Time.now
      if $newgen
        internal_error("Thing at line #{__LINE__} not yet implemented for -n / newgen")
      else
        delete_user_internal(@base_uri, user, auth_hdr(nil))
      end
      rec_dev_action_result_norm(false, beg_time)
    end

    def find_services(app, user, client, svcs)
      # Bail if there are no services to be provisioned
      return nil, false unless svcs and svcs.kind_of? Array and svcs.length > 0

      # Get hold of the available services
      beg_time = Time.now
      if $newgen
        begin
          asvcs = client.services_info
        rescue => e
          @logger.warn("Request for available services failed: #{e.inspect}")
          return [],nil
        end
      else
        response = get("#{@base_uri}/info/services", nil, auth_hdr(nil))
        return [],nil unless handle_response(response, beg_time)
        asvcs = JSON.parse(response.content)
      end

      # This weird flag excludes "*.sqlite3" from the push tarball or something
      hasdb = false

      # For each service the app is asking for, try to find an available match
      provs = []
      svcs.each do |asks|
        s_type = asks[:svc_type]
        s_vend = asks[:svc_vendor]
        s_vers = asks[:svc_version]

        # Find services that match the desired type/vendor/etc.
        s_list = []
        asvcs.each do |type, vendors|
        ##puts "Service type=#{type} vs. #{s_type}, vend=#{vendors.inspect}"
          next if s_type.to_s != type.to_s and type != "generic"
          vendors.each do |vendor, versions|
          ##puts "  Vendor: #{vendor} vs. #{s_vend}, vers=#{versions.inspect}"
            next if s_vend and s_vend.to_s != vendor.to_s
            versions.each do |version, entry|
            ##puts "    Version: #{version} vs. #{s_vers} -> #{entry.inspect}"
              next if s_vers and s_vers.to_s != version.to_s

              # Pick the free tier or whatever tier is first (if any)
              tiers = $newgen ? entry[:tiers] : entry["tiers"]
              tiers = entry["plans"] unless tiers
            ##puts "      Tiers: #{tiers.inspect}"
              if tiers.kind_of? Array
                tier = nil
                tiers.each do |t|
                  tier = "free" if t.kind_of? Hash   and t[:name] == "free" # old style
                  tier = "free" if t.kind_of? String and t        == "free" # new style
                end
                tier = tiers[0]["name"] unless tier
              else
                tier = (tiers.size > 1 and tiers.has_key?("free")) ? "free" : tiers.keys.first
              end

              # UNDONE: grab tier options, if present
              opts = nil

              # Looks like a service we can use - add it to the list
              s_list << {
                          :type    => type,
                          :desc    => entry[:vendor], # weird temporary hack for NG client
                          :vendor  => vendor,
                          :version => version,
                          :tier    => tier,
                          :options => opts
                        }
            end
          end
        end

        # Do we have exactly one matching service?
        if s_list.length != 1
          internal_error("Found #{s_list.length} matching services for type=#{s_type},vendor=#{s_vend},version=#{s_vers}")
        end

        # Add this service to the list we need to provision
        provs << s_list[0]

        # Weird thing (no idea why)
        hasdb = true if s_type == "database"
      end

      # Return the services to be provisioned (and the 'db' flag)
      return provs, hasdb
    end

    def del_app_service(app, user, client, svcs)
      # Get the list of services currently provisioned to the app
      info = get_app_info(app, user, client)
      psvc = info['services']

      # Process each service the caller specified
      svcs = [svcs] if svcs.kind_of? Hash
      svcs.each do |svc|
          # Find a provisioned service that matches the description
          svc_name = find_matching_service(app, user, client, psvc, svc)
          if not svc_name
            @logger.error("Could not delete #{svc.inspect} for app #{app}")
            next
          end

          # Delete the entry from the app's provisioned services
          psvc.delete(svc_name)
          info['services'] = psvc

          # Tell AC that this app no longer needs this service
          begin
            beg_time = Time.now
            if $newgen
              internal_error("Thing at line #{__LINE__} not yet implemented for -n / newgen")
            else
              response = update_app_state_internal(@droplets_uri, app, info, auth_hdr(user))
            end
            handle_response(response, beg_time)
          rescue => e
            @logger.error("Unbind failed for service #{svc_name} / #{svc.inspect} for app #{app}")
          end

          # Finally, remove the service from the user
          if $newgen
            internal_error("Thing at line #{__LINE__} not yet implemented for -n / newgen")
          else
            remove_service_internal(@services_uri, svc_name, auth_hdr(user))
          end
      end
    end

    def execute_plan(queue, dry_run, user_count, context_count)
      @logger.info("Starting test plan execution")

      # The following will record the currently executing command(s)
      @exec_thrd_cnt = @config['thread_count'] ? @config['thread_count'] : 1
      @cur_dev_cmds  = [nil] * @exec_thrd_cnt

      @logger.info("Using #{@exec_thrd_cnt} threads")

      # Combine the target URL to create the various URL's we'll be using
      @base_uri      = "http://" + @target
      @droplets_uri  = "#{@base_uri}/apps"
      @services_uri  = "#{@base_uri}/services"
      @resources_uri = "#{@base_uri}/resources"

      # Are we really doing this, or just pretending?
      dry_run = @config['dry_run_plan']

      # The following will hold the test user clients / emails / auth_tokens
      @user_clients  = []
      @user_emails   = []
      @user_tokens   = []

      # We'll try to figure out the peak instance count of the run
      @cur_instances = 0
      @max_instances = 0

      # Initialize the "stop now" and "test is finished" flags
      @stop_run_now  = false
      @test_run_done = false

      # Initialize the stats we keep for "dev" actions
      @dev_act_cnt_n = 0  # count of "normal" dev actions that went OK
      @dev_act_cnt_s = 0  # count of  "slow"  dev actions that went OK
      @dev_act_fails = 0  # count of  *all*   dev actions that failed
      @dev_act_nrmtm = 0  # total time spent executing "normal" dev actions
      @dev_act_slwtm = 0  # total time spent executing  "slow"  dev actions

      # Login as an administrator
      if not dry_run
        if $newgen
          # Create client instance for the admin user
          # FIXME: later usage of this client is not thread safe.
          @admin_client = VMC::Client.new(@target)
          @admin_client.proxy = nil

          # Log in the admin user
          @admin_token = @admin_client.login(@config['ac_admin_user'], @config['ac_admin_pass'])

          # Enable tracing if desired
          @admin_client.trace = $verbose ? true : false
        else
          @admin_token = login_internal(@base_uri, @config['ac_admin_user'],
                                                   @config['ac_admin_pass'])
        end
      else
        @admin_token = "this is a fake admin user token"
      end

      # Prepare an array to hold the client instances for each user
      user_clients = [nil] * user_count

      # Figure out whether we should try to follow a "real" clock
      real_clock = dry_run ? false : true

      # Initialize the clock and start executing the commands in the queue
      stclk = Time.now
      clock = 0

      # The following holds info about all of the active apps
      my_apps = {}
      ma_lock = Mutex.new

      # Start a thread to log CPU/memory usage, if desired
      if @config['log_rsrc_use'] and @config['log_rsrc_use'] > 0
        Thread.new do
          slp = @config['log_rsrc_use']
          cmd = "ps -o rss=,pcpu= -p #{Process.pid}"
          while slumber(slp)
            rss, cpu = `#{cmd}`.split
            mem = (rss.to_i + 511) / 1024
            @logger.info("Current resource usage: mem =%4u MB , cpu = %4.1f \%" % [mem, cpu.to_f])
          end
        end
      end

      # Count the number of dev/use actions (excluding infinite uses); also,
      # adjust the clock values so that the first action happens right away.
      start_clock    = queue[0][:clock]
      @use_act_count = 0
      @dev_act_count = 0
      queue.each do |q|
        # Adjust the clock
        q[:clock] -= start_clock

        # For 'use' actions, don't count infinite duration entries
        if q[:act_type].kind_of? STAC::TestDef_Use
          arg = q[:args]
          @use_act_count += 1 unless arg and arg[:duration] == INFINITY
        end

        # Note - 'dev' actions should never have infinite durations
        if q[:act_type].kind_of? STAC::TestDef_Dev
          @dev_act_count += 1
        end
      end

      priority_context_queue = PriorityContextQueue.new(@logger, queue)

      # Start the desired number of threads to execute the test actions
      thrd_cnt = @exec_thrd_cnt
      thrd_tab = []
      thrd_cnt.times do |thrd_num|
        # This is the start each executor thread ...
        thrd_tab << Thread.new do
          while !@stop_run_now and !@test_run_done

            # We need to pull the next available action and run it. We prevent
            # collisions on the client associated with each context by only
            # running 1 item from each context queue at a time (that is what
            # the old code did too)
            #
            # The basic algorithm for grabbing action items from the queue
            # is as follows:
            #
            #   1.
            #   Pull a context queue off the priority queue.  If nil,
            #   we are done as there is no more work to do.  Shift an action
            #   off the context queue.
            #
            #   2.
            #   Compare the current time to the clock value in the first
            #   undone item we found in the previous step; if the item is
            #   way in the future, that means that there is no work to be
            #   done at this time; go to sleep long enough such that we'll
            #   wake up around the time the next item is due; start all
            #   over after waking up.

            # Step 1: get a context_queue from the priority queue, if nil,
            # there is no more work to do.
            a_our = nil
            context_queue = priority_context_queue.pop
            break unless context_queue

            # Get and record the currently executing action for this thread
            a_our = context_queue.shift
            @cur_dev_cmds[thrd_num] = a_our

            # Step 2: if the item is in the future, go to sleep
            # (this is the sleep block from the older code, just shifted over
            # due to shifting out a block level)
            a_clk = a_our[:clock]
            c_clk = real_clock ? (Time.now - stclk) : a_clk
            if c_clk < a_clk
              # Randomize the sleep time a tiny bit to avoid bad behavior
              slptm = (real_clock ? (a_clk - c_clk) : 0) + rand(0.1)
              @logger.debug("Next action #{action_to_s(a_our)} in T#{thrd_num} isn't due for #{slptm} seconds") if slptm > 60
              sleep(slptm)
            end

            # Put this back to what the "old" code expects, including the
            a = a_our

            # Stop if we're shutting down
            break if @stop_run_now

            # If the above loop stops without finding 'a', it means we're done
            break unless a

            # We wrap the rest of the logic in an 'ensure' block to guarantee
            # that we can do appropriate cleanup and accounting
            begin
              retry_action = false

              typ = a[:act_type]
              clk = a[:clock]
              act = a[:action]
              arg = a[:args]

              ctx = a[:context]
              usr = ctx[0]
              scn = ctx[1]

              # Do we have a "use" or "dev" action to execute?
              if typ.kind_of? STAC::TestDef_Use
                # Make sure all "use" actions are :symbols
                internal_error("Use action value is not a :symbol") unless act.kind_of? Symbol

                # Pull out the :http_args value, if present
                harg = TestDef_Base.pull_val_from(arg, :http_args)

                do_use_action(usr, scn, act, arg, harg, clk, dry_run)

                # Update the remaining "use" action count
                if arg[:duration] != INFINITY
                  @lck_act_count.synchronize { @use_act_count -= 1 }
                end

                next
              end

              # Not "use" - must be a "dev" (i.e. an AC user / admin type) action
              internal_error("Instead of use/dev action we found #{a.class}") unless typ.kind_of? STAC::TestDef_Dev
              internal_error("Dev action value is not a Fixnum") unless act.kind_of? Fixnum

              # Figure out when this action should end
              dur = arg[:duration] || 0
              end_time = Time.now + dur

              # Extract the app name, if present
              app = ""
              if arg and arg[:app_name]
                app = arg[:app_name]
              end

              # Get hold of the client / auth token / email for this user (if set)
              client = @user_clients[usr]
              token  = @user_tokens [usr]
              email  = @user_emails [usr]

              # Extract instance info, if present
              icnt = arg[:inst_cnt]
              iinc = nil
              if icnt
                # If the count starts with +/- then it's a relative change
                if icnt.kind_of? String
                  iinc = icnt[0,1]
                  if iinc != "+" and iinc != "-"
                    iinc = nil
                  end
                end
                icnt = eval_exec_arg(icnt, app, email).to_i
              end

              imin = arg[:inst_min] ? eval_exec_arg(arg[:inst_min], app, email).to_i : nil
              imax = arg[:inst_max] ? eval_exec_arg(arg[:inst_max], app, email).to_i : nil
              inum = arg[:inst_num] ? eval_exec_arg(arg[:inst_num], app, email).to_i : nil

              @logger.info("[%04u]>>vmc \{#{ctx_mark(usr,scn)}\} #{VMC_Actions.action_to_s(act)} #{app} #{arg.inspect}" % clk)

              # With a few exceptions, all commands refer to active apps
              case act
              when VMC_Actions::VMC_ADD_USER,
                   VMC_Actions::VMC_DEL_USER,
                   VMC_Actions::VMC_PUSH_APP

              else
                # We should have an app descriptor in our table for the app
                ainf = my_apps[app]
                if not ainf
                  internal_error("my_apps[\'#{app}\'] is missing for user #{email} at #{VMC_Actions.action_to_s(act)}")
                end
              end

              # See what action is specified and carry it out
              case act
              when VMC_Actions::VMC_ADD_USER
                mail   = arg[:email]
                pass   = arg[:password]
                client = nil
                if not dry_run
                  begin
                    beg_time = Time.now
                    if $newgen
                      # We potentially need to delete the user from an unclean shutdown
                      begin
                        @logger.debug("Deleting user: '#{mail}'")
                        @admin_client.delete_user(mail)
                        @logger.debug("Deleted user: '#{mail}'")
                      rescue VMC::Client::NotFound
                        @logger.debug("Did not need to clean up user: '#{mail}'")
                      rescue => e
                        @logger.info("Unexpected error while deleting user: '#{mail}' error: '#{e.inspect}'")
                      end

                      # Create the test user
                      ur = @admin_client.add_user(mail, pass)

                      # Create a client for the user
                      client = VMC::Client.new(@target, @admin_token)
                      client.proxy = nil

                      # Login the client and set the proxy value in the client
                      client.login(@config['ac_admin_user'], @config['ac_admin_pass'])
                      client.proxy = mail

                      # Enable tracing if desired
                      @admin_client.trace = $verbose ? true : false
                    else
                      begin
                        @logger.debug("Deleting user: '#{mail}'")
                        delete_user_internal(@base_uri, mail, auth_hdr(nil))
                        @logger.debug("Deleted user: '#{mail}'")
                      rescue => e
                        # Errors will be the common case
                        @logger.debug("Error deleting user: '#{mail}' error: '#{e.inspect}'")
                      end
                      register_internal(@base_uri, mail, pass)
                    end
                    rec_dev_action_result_norm(false, beg_time)
##hack##          rescue VMC::Client::NotFound
##hack##            rec_dev_action_result_norm(true , beg_time)
##hack##            fatal_error("Could not register test user #{mail}: probably a turd left behind, please reset CC/HM database")
                  rescue => e
                    rec_dev_action_result_norm(true , beg_time)
                    if e.kind_of? RuntimeError and e.to_s[0, 14] == "Invalid email:"
                      fatal_error("Could not register test user #{mail}: probably a turd left behind, please reset CC/HM database")
                    else
                      @logger.error("Could not register test user #{mail}")
                      raise e, e.message, e.backtrace
                    end
                  end
                  token = login_internal(@base_uri, mail, pass)
                else
                  token = "this is a fake token for user #{usr}"
                end

                @user_clients[usr] = client
                @user_tokens [usr] = token
                @user_emails [usr] = mail

                @cleanup_lock.synchronize {
                  @cleanup = [ { :action => VMC_Actions::VMC_DEL_USER, :user => mail } ] + @cleanup
                  @cleanup_acts += 1
                }

              when VMC_Actions::VMC_PUSH_APP
                # Get the various arguments we need to push app bits
                path = TestDef_Base.pull_val_from(arg, :path)
                aurl = TestDef_Base.pull_val_from(arg, :url)
                amem = TestDef_Base.pull_val_from(arg, :mem)
                awar = TestDef_Base.pull_val_from(arg, :war)
                inst = TestDef_Base.pull_val_from(arg, :instances)
                fmwk = TestDef_Base.pull_val_from(arg, :framework)
                exec = TestDef_Base.pull_val_from(arg, :exec_cmd)
                svcs = TestDef_Base.pull_val_from(arg, :services)
                crsh = TestDef_Base.pull_val_from(arg, :crashes)

                # Create and record the app descriptor
                ainf = {
                         :user         => usr,
                         :inst_total   => 0,
                         :inst_running => 0,
                         :inst_crashed => 0,
                         :crash_info   => crsh,
                       }
                ma_lock.synchronize { my_apps[app] = ainf }

                if not dry_run

                  manifest = {
                    :name => "#{app}",
                    :staging => {
                      :framework => fmwk,#changed by jacky
                      :runtime => exec#changed by jacky
                    },
                    :uris      => [aurl],
                    :instances => 1,
                    :resources => { :memory => mem_in_MB(amem) },
                  }

                  # Provision services if the app asked for any
                  provs, hasdb = find_services(app, email, client, svcs)

                  # Send the manifest to the cloud controller
                  beg_time = Time.now
                  begin
                    # Create the app
                    if $newgen
                      client.create_app(app, manifest)
                      rec_dev_action_result_norm(false, beg_time)
                    else
                      response = create_app_internal(@droplets_uri, manifest, auth_hdr(email))
                      handle_response(response, beg_time)
                      #client = VMC::Client.new(@base_uri, @admin_token)
                      #client.create_app(arg[:app_name], manifest)
                    end

                    # App created - make sure we delete it no matter what happens
                    @cleanup_lock.synchronize do
                      @cleanup = [ { :action => VMC_Actions::VMC_DEL_APP, :client   => client,
                                                                          :user     => email,
                                                                          :app_name => app } ] + @cleanup
                      @cleanup_acts += 1
                    end

                    # Now upload the app bits
                    pushed = push_app_bits(app, email, client, false, path, provs, awar, hasdb)
                  rescue => e
                    rec_dev_action_result_norm(true , beg_time)
                    @logger.error("Could not create app #{app} -- #{e.inspect}")
                    pushed = false
                  end

                  # If pushed OK, wait for the correct number of running instances
                  if not pushed or set_instance_count(app, email, client, inst, true, ainf) == 0
                    break if @stop_run_now

                    # Zap all future actions related to this app
                    orig_len = context_queue.length
                    context_queue.delete_if {|a| a[:args] and a[:args][:app_name] == app and not a[:act_type].kind_of? STAC::TestDef_Use}
                    aborted = @lck_act_count.synchronize { aborted = orig_len - context_queue.length }
                    @lck_act_count.synchronize {
                      @dev_act_count   -= aborted
                      @dev_act_done    += aborted
                      @dev_act_aborted += aborted
                    }

                    # We couldn't push or get even one instance of the app running
                    @logger.error("Could not get app #{app} started; aborting run and #{aborted} actions")
                  end
                end

              when VMC_Actions::VMC_UPD_APP

                adef = arg[:app_def]
                if not adef.kind_of? TestDef_App
                  internal_error("Bogus update app type of #{adef.class}")
                end
                begin
                  push_app_bits(app, email, client, true, adef.dir) unless dry_run
                rescue Errno::EACCES => e
                  @logger.warn("Update for app #{app} failed: #{e.inspect}")
                  raise e, e.message, e.backtrace
                end

                # Did we just change the crash mode of the app?
                ainf = my_apps[app]
                oldc = ainf[:crash_info]
                newc = adef.crashes
                if oldc != newc
                  # UNDONE: crash mode changed from #{oldc} to #{newc} for app #{app}
                  ainf[:crash_info] = newc
                end

              when VMC_Actions::VMC_DEL_APP

                if @config['pause_at_end'] or @config['log_end_stat']
                  @logger.warn("Skipping deletion of app #{app}") unless dry_run
                else
                  begin
                    if $newgen
                      internal_error("Action #{VMC_Actions.action_to_s(act)} not yet implemented for -n / newgen")
                    else
                      delete_app(app, email, client) unless dry_run
                    end
                  rescue => e
                    @logger.warn("Deleting app #{app} threw #{e.inspect}")
                  end

                  # Remove the app from the "active apps" table
                  ma_lock.synchronize { my_apps.delete(app) }

                  # Find and kill the cleanup action for this app
                  @cleanup.each do |aa|
                    if aa[:action]   == VMC_Actions::VMC_DEL_APP and
                       aa[:user]     == email and
                       aa[:app_name] == app then

                      # Deactivate this cleanup item
                      aa[:action] = 0

                      # Decrement number of cleanup items left to process
                      @cleanup_lock.synchronize { @cleanup_acts -= 1 }
                      break
                    end
                  end
                end

              when VMC_Actions::VMC_CHK_APP

                if not dry_run
                  # Get the current instance counts and compare against expected
                  cnts = app_instance_count(app, email, client)

                  @logger.debug("Checking app health: crash mode is \'#{ainf[:crash_info]}\' and instances are #{cnts.inspect}")

##################puts "Checking app health: crash mode is \'#{ainf[:crash_info]}\' and instances are #{cnts.inspect}"

                  if cnts[0] != ainf[:inst_total  ] or
                     cnts[1] != ainf[:inst_running] or
                     cnts[2] != ainf[:inst_crashed] then
                    # ISSUE: if there are zero running instances, should we abort?
                    # UNDONE: what else do we need to do here?
                    @logger.warn("app #{app}: instCnt(total) is #{cnts[0]} instead of #{ainf[:inst_total  ]}") unless cnts[0] == ainf[:inst_total  ]
                    @logger.warn("app #{app}: instCnt(runng) is #{cnts[1]} instead of #{ainf[:inst_running]}") unless cnts[1] == ainf[:inst_running]
                    @logger.warn("app #{app}: instCnt(crshd) is #{cnts[2]} instead of #{ainf[:inst_crashed]}") unless cnts[2] == ainf[:inst_crashed]
                  end

                end

              when VMC_Actions::VMC_INSTCNT

                # Do we have a specific instance count change or min/max?
                if icnt
                  # Was the count "+xxx" or "-xxx" ?
                  if iinc
                    ncnt = (dry_run ? 0 : app_instance_count(app, email, client)[1]) + icnt
                    # Make sure the new instance count isn't too low
                    ncnt = 1 if ncnt < 1
                  else
                    ncnt = icnt.to_i
                  end
                  if not dry_run
                    set_instance_count(app, email, client, ncnt, false, ainf)
                  end
                else
                  puts "UNDONE: handle min/max instance count action" ; exit
                end

              when VMC_Actions::VMC_ADD_SVC

                # We should have a :services value (and it must be an array/hash)
                svcs = arg[:services]
                internal_error("Missing :services value in 'add service' action") if not svcs
                if svcs.kind_of? Hash
                  svcs = [ svcs ]
                else
                  internal_error("The :services value #{svcs} in 'add service' is of type #{svcs.class}") unless svcs.kind_of? Array
                end

                if not dry_run
                  # Look for available service(s) to satisfy the request
                  prov, = find_services(app, email, client, svcs)

                  # Bind the services(s) to the user and this app
                  begin
                    prov.each { |p| add_app_service(app, email, p) }
                    @logger.debug("Added service(s) #{svcs.inspect} to app #{app}")
                  rescue Errno::EACCES => e
                    @logger.warn("Adding services to app #{app} failed: #{e.inspect}")
                  end
                end

              when VMC_Actions::VMC_DEL_SVC

                # We should have a :services value (and it must be an array/hash)
                svcs = arg[:services]
                internal_error("Missing :services value in 'delete service' action") if not svcs
                if svcs.kind_of? Hash
                  svcs = [ svcs ]
                else
                  internal_error("The :services value #{svcs} in 'delete service' is of type #{svcs.class}") unless svcs.kind_of? Array
                end
                if not dry_run
                  del_app_service(app, email, svcs)
                  @logger.debug("Deleted service(s) #{svcs.inspect} from app #{app}")
                end

              when VMC_Actions::VMC_APPLOGS, VMC_Actions::VMC_CRSLOGS

                if not dry_run
                  # ISSUE: for crash logs we make sure there are actually crashes
                  #        present before trying to get any logs. Is this correct?
                  crash = get_app_crashes(app, email, client)
                  if not crash or crash.length == 0
                    @logger.debug("app #{app} has no crashes; ignoring get_crash_logs action")
                    next
                  end
                end

                # Get the current number of running instances
                inst = dry_run ? 1 : app_instance_count(app, email, client)[0]

                # Are we supposed to choose random instances?
                irnd = arg[:random] ? true : false

                # The meaning of the various instance values is as follows:
                #
                #   icnt        if present, get that many random instance logs
                #
                #   imin/imax   if present, random number of logs in <min .. max>
                #
                #   inum        if present, use the specific instance number; if
                #               negative, get logs for that many random instances

                # What kind of an instance count / number do we have?
                if icnt
                  # Simple count
                  lcnt = icnt
                  # We better not have min/max or 'inst_num'
                  if imin or imax or inum
                    puts "ERROR: crazy mix of icnt/imin/imax/inum" ; exit
                  end
                elsif imin or imax
                  # We better have both min/max and no 'inst_num'
                  if not imin or not imax or inum
                    puts "ERROR: crazy mix of imin/imax/inum" ; exit
                  end
                  # If min/max is negative, choose a random count
                  if imin < 0 or imax < 0
                    imin = -imin if imin < 0
                    imax = -imax if imax < 0
                    irnd = true
                    lcnt = imin + rand(imax - imin)
                  else
                    lcnt = imax - imin + 1
                  end
                  inum = imin
                elsif inum
                  lcnt = inum
                  if inum < 0
                    irnd = true
                    lcnt = -inum
                    inum = nil
                  end
                else
                  puts "ERROR: no icnt / imin / imax / inum found" ; exit
                end

                if not dry_run
                  # Pull the desired number of app/crash logs
                  lcnt.times do
                    # Pick a random instance unless we have a specific instance number
                    if irnd
                      # UNDONE: for crash logs we need to pick a crashed instance
                      inum = rand(inst).to_i
                    else
                      inum = 0 if inum >= inst
                    end

                    if act == VMC_Actions::VMC_APPLOGS
                  ####puts "Getting app   log for #{app}:#{inum}"
                      grab_app_logs(app, email, inum) unless dry_run
                    else
                  ####puts "Getting crash log for #{app}:#{inum}"
                      grab_crash_logs(app, email, client, inum) unless dry_run
                    end

                    inum += 1
                  end
                end

              when VMC_Actions::VMC_CRASHES
                if not dry_run
                  crash = get_app_crashes(app, email, client)
                end

              else
                internal_error("Unexpected 'dev' action \"#{VMC_Actions.action_to_s(act)}\"")
              end
            rescue => e
              # put our action back on and delay this and any other actions for this
              # app by to give the CC a chance to recover
              defer_time = 60
              retry_action = true
              @logger.error("Execution plan error. Deferring for #{defer_time}s #{a_our.inspect}")
              context_queue.unshift(a_our)
              new_start = Time.now - stclk + defer_time
              context_queue.each do |a|
                diff = a_our[:clock] - a[:clock]
                a[:clock] = new_start + diff if a[:args].nil? or a[:args][:app_name] == app
              end
            ensure
              if a_our and not retry_action and not typ.kind_of? STAC::TestDef_Use
                @lck_act_count.synchronize {
                  @dev_act_count -= 1
                  @dev_act_done  += 1
                }
              end

              # Make sure the action takes the proper amount of time
              slumber(end_time - Time.now) unless dry_run

              # This context queue is ready for more work
              priority_context_queue.push(context_queue) if context_queue and not context_queue.empty?

              # This thread is no longer executing anything
              @cur_dev_cmds[thrd_num] = nil
            end
          end
        end
      end

      # Save the execution thread table in case something goes wrong
      @exec_thrds = thrd_tab
      @exec_thrds.each { |t| t.abort_on_exception = true }

      # Create a thread that will kill everything if/when 'max_runtime' is reached
      if @config['max_runtime']
        time_killer_thread = Thread.new do
          bgtm = Time.now
          slen = tlen = @config['max_runtime'].to_i
          while slen > 0 and not @test_run_done and not @stop_run_now
            sleep   0.5
            slen -= 0.5
          end
          if not @test_run_done and not @stop_run_now
            msg = "Test has been running for #{(Time.now-bgtm).to_i} seconds: trying to stop it"
            @logger.warn(msg)
            puts         msg

            # Tell everyone that it's time to stop
            if not force_stop
              sleep(1)
              # If we've starting cleaning up, no need to panic
              if not @doing_cleanup
                msg = "Execution threads refuse to stop; aborting the test the hard way"
                @logger.error(msg)
                puts          msg
                exit!
              end
            end
          end
        end
      end

      # Start a warm-and-fuzzy thread that will regularly display statistics
      fuzzy_thread = Thread.new do
        # We'll display time elapsed in our updates
        start = Time.now

        # Get hold of the update period in seconds
        freq = @config['update_freq'].to_f
        freq = 60 unless freq                 # default = 60 seconds

        while not @test_run_done and not @stop_run_now
          stamp = "[%04u sec]: " % (Time.now - start + 0.5).to_i
          report_averages(true , stamp)
          report_averages(false, stamp)

          @logger.debug("priority queue len: #{priority_context_queue.length}")
          txt = ""
          @cur_dev_cmds.each_with_index do |action, thrd|
            txt += "   Thread #%02u " %thrd
            if action
              txt += "is executing action #{action.inspect}\n"
            else
              txt += "is in IDLE\n"
            end
          end
          @logger.debug("thread state:\n#{txt}")

          # Sleep 'freq' seconds (while checking for the test ending)
          slumber(freq)
        end
      end

      # Wait for the execution threads to finish
      thrd_tab.each { |t| t.join }

      # Dump summary + log detailed final state if desired
      if @config['log_end_stat'] and not dry_run
        fin_usrs = 0 # number of users we find alive
        fin_apps = 0 # number of apps  we find alive
        fin_good = 0 # number of app instances that look healthy/running
        fin_sick = 0 # number of app instances that look  sickly/crashed

        @logger.info("Detailed end state:")

        # Iterate across all the user we (probably) created
        for u in 0..user_count-1 do
          user = @user_emails [u]
          clnt = @user_clients[u]
          next unless user

          @logger.info("User #{user}:")

          # We have a live user, apparently
          fin_usrs += 1

          # Enumerate this user's applications (if any)
          my_apps.each do |name, ainf|
            next unless ainf[:user] == u
            tcnt, rcnt, ccnt = app_instance_count(name, user, clnt)
            @logger.info("    App #{name}: T=#{tcnt},R=#{rcnt},C=#{ccnt}")
            fin_good += rcnt
            fin_sick += ccnt
          end
        end

        msg  = "#{fin_usrs} live users with #{fin_apps} apps"
        msg += ", #{fin_good} instances good" if fin_good > 0
        msg += ", #{fin_sick} instances sick" if fin_sick > 0

        @logger.info("[final]: " + msg)
        puts "End state: #{msg}"
      end

      # The run ended peacefully - see if we are supposed to pause
      if @config['pause_at_end']
        puts ; puts ; puts
        puts "----------------------------------------------------------"
        puts "Test run ended successfully - please hit enter to clean up"
        STDIN.gets
        puts "----------------------------------------------------------"
      end
    ensure
      @test_run_done = true
      cleanup
      final_report
    end

    def final_report
      @logger.info("Peak app instance count was about #{@max_instances}") if @max_instances != 0
      @logger.info("Estimated instance count error is #{@cur_instances}") if @cur_instances != 0

      if not @config['dry_run_plan']
        report_averages(true,  "[final]: ")
        report_averages(false, "[final]: ")
      end
    end

    def cleanup
      return unless @cleanup_acts > 0

      dry_run = @config['dry_run_plan']

      @doing_cleanup = true

      @cleanup_lock.synchronize do
        @logger.info("CLEANUP: start")

        # Figure out how often we should display progress
        tcnt = @cleanup_acts
        ucnt = tcnt / 10

        # Display updates with a reasonable frequency - not too low, not too high
        ucnt = 50     if ucnt > 50
        ucnt = tcnt+1 if ucnt < 5 or $bequiet or @config['dry_run_plan']

        puts "[CLEANUP] #{tcnt} entries to process" if tcnt > 50

        ccnt = 0
        ncnt = ucnt
        @cleanup.each do |a|
          # Grab the next cleanup action and skip it if it's nil
          act = a[:action] ; next unless act and act > 0

          # Mark the action as done, and update overall count
          a[:action] = 0 ; @cleanup_acts -= 1

          # If this is a "dry run", we never do any real stuff
          next if dry_run

          # Issue occassional updates so the operator doesn't panic
          ccnt += 1
          if ccnt >= ncnt
            pct = (100.0 * ccnt / tcnt + 0.5).to_i
            if pct <= 99
              puts "[CLEANUP] about %02u%% done (#{ccnt} of #{tcnt} items processed)" % pct
            end
            ncnt += ucnt
          end

          # Perform the cleanup action
          case act
          when VMC_Actions::VMC_DEL_USER
            user = a[:user]
            begin
              if $newgen
                @admin_client.delete_user(user)
              else
                delete_user(user)
              end
            rescue => e
              @logger.warn("CLEANUP: deleting user #{user} threw #{e.inspect}")
            end

          when VMC_Actions::VMC_DEL_APP
            app    = a[:app_name]
            user   = a[:user]
            client = a[:client]
            begin
              if $newgen
                client.delete_app(app)
              else
                delete_app(app, user, client)
              end
            rescue => e
              @logger.warn("CLEANUP: deleting app #{app} threw #{e.inspect}")
            end
          else
            puts "UNDONE: cleanup action #{VMC_Actions.action_to_s(act)} #{a.inspect}"
          end

        end

        @logger.warn("CLEANUP: bad accounting -- #{@cleanup_acts}") if @cleanup_acts != 0

        @logger.info("CLEANUP: done")
      end
    end

    def force_stop
      return unless @cur_dev_cmds

      # Tell the executor and HTTP use threads that we want to stop
      @stop_run_now = true
      @use_runner.stop_test if @use_runner

      # Give everyone a chance, but only up to a certain amount of time
      20.times do
        sleep(0.5)
        return true if @test_run_done or @doing_cleanup
      end

      # The gloves come off ...
      @cur_dev_cmds.each_with_index do |a,tx|
        puts("Thread #%02u is executing action #{action_to_s(a)}" % tx) if a
      end

      false
    end

    def abort_test
      puts "Attempting to stop the test run"
      force_stop
      if not @test_run_done
        cleanup
        final_report
      end
    end

  end # class StressTestExec

  # Return a string to prefix action display: "clock : user / scenario"
  def self.act_prefix(clock, state)
    u = state[:ac_user_num] ? ("u%03u" % state[:ac_user_num]) : "uuuu"
    s = state[:ac_scen_num] ? ("s%02u" % state[:ac_scen_num]) : "sss"
    ("%04u" % clock) + ":#{u}/#{s}"
  end

  class ActionQueue
    @@queue_lock = Mutex.new
    @@queue_list = []
    @@queue_val  = []
    @@jitter     = 0
    @@logger     = nil
    @@max_clock  = 0

    def self.set_logger(logger)
      @@logger = logger
    end

    def self.record_queue(q)
      @@queue_lock.synchronize { @@queue_list << q }
    end

    def self.enqueue(inst, clock, state, action, args, disp)
      @@queue_lock.synchronize do
        @@logger.debug("        [#{STAC::act_prefix(clock, state)}] >>" + disp)
        @@queue_val <<
        {
          :context  => [ state[:ac_user_num] , state[:ac_scen_num] ],
          :uniquex  => state[:uniquex],
          :act_type => inst,
          :clock    => clock,
          :action   => action,
          :args     => args,
          :seq      => @@queue_val.length
        }
        @@max_clock = clock if @@max_clock < clock
      end
    end

    def self.enqueue_dev(inst, clock, state, action, appname, args = nil)
      disp = "vmc #{VMC_Actions.action_to_s(action)} #{appname} #{args.inspect}"
      args = args ? args.dup : {}
      args[:app_name] = appname
      enqueue(inst, clock, state, action, args, disp)
    end

    def self.enqueue_use(inst, clock, state, action, args)
      if not action.kind_of? Symbol
        puts "FATAL: use actions must always have :action" ; exit
      end
      disp = "use #{args.inspect}"
      enqueue(inst, clock, state, action, args, disp)
    end

    def self.merge_queues
      @@queue_val.sort do |a, b|
        if a[:clock] == b[:clock]
          a[:seq  ] <=> b[:seq  ]
        else
          a[:clock] <=> b[:clock]
        end
      end
    end

    def self.set_jitter(jitter)
      if jitter < 0 or jitter > 100
        puts "FATAL: clock jitter value is #{jitter}, should be between 0 and 100"
        exit
      end
      @@jitter = jitter.to_i
    end

    def self.action_duration(dur)
      return 0 unless dur
      return rand(-dur) if dur < 0
      return dur if dur == INFINITY
      dur ? (dur + (rand(200) - 100) / 100.0 * dur / 100.0 * @@jitter).to_i : 0
    end
  end

  # The base for the various classes that hold definition info:
  class TestDef_Base

    attr_accessor :srcf
    attr_accessor :data
    attr_accessor :id
    attr_accessor :desc

    def initialize(srcf, data)

      # Save the source file (used for error messages)
      @srcf = srcf

      # Pull out "id" if present
      @id   = "<NULL>"
      if data and data[:id]
        @id = data[:id]
        data.delete(:id)
      end

      # Pull out "description" if present
      @desc = "<factory rep instance>"
      if data and data[:description]
        @desc = data[:description]
        data.delete(:description)
      end

      @data = data
    end

    def self.set_logger(logger)
      @@logger = logger
    end

    def self.pull_val_from(data, key)
      return nil unless data
      val = data[key]
      return nil unless val     # should report an error for missing values?
      val
    end

    def pull_val(key)
      TestDef_Base.pull_val_from(@data, key)
    end

    def self.pull_action_id(data)
      return nil, nil unless data
      # No guarantee of ordering so we need to fish for the action id
      data.each do |k, v|
        # Look for a key that has a nil value (to simplify things)
        if not v
          # For now, a simple hard-wired string check
          if k.to_s[0,5] == "stac_"
            data.delete(k)
            return k, data
          end
        end
      end
    end

    # Given a definition id, break it down into its type and "naked" id;
    # always returns two values, as follows:
    #
    #    def_instance,naked_id  ...   when the "id" is kosher
    #
    #    nil,error_string       ...   in case of a problem
    #
    def self.parse_def_id(name)
      # If there is no name, we bail immediately
      return nil, "could not find a string :id value" unless name and name.kind_of? String

      # Extract the "id" prefix and the "naked" id from the string
      parts = name.match(/^stac_([a-z]+[a-z0-9]*)_([a-z0-9_]+)/)
      return nil, "type is not recognized in #{name}" unless parts && parts.length == 3

      # Make sure the "id" is known
      idef = Def_mapps[parts[1]]
      #puts(parts[1])#Add by jacky
      return nil, "type \'#{parts[1]}\' of 'id' value \'#{name}\' is not recognized" unless idef

      # Everything looks good, return the instance and the "naked" id
      return idef, parts[2]
    end

    # Check a definition reference - usually just dispatches to the appropriate subclass
    def self.check_def_use(user, id, idx, args = nil)
      idef, bsid = TestDef_Base.parse_def_id(id.to_s)
      if idef
        ichk = idef.find_id(bsid)
        return ichk.check_ref(user, args) if ichk
        kind = "unknown"
      elsif id.to_s[0, ARG_SUB_PREFIX.length] == ARG_SUB_PREFIX
        # UNDONE: Make sure the substitution looks reasonable (how?)
        return id,args  # should we wrap the "id" in something?
      else
        kind = "bogus"
      end
      show = ""
      if idx
        show = (idx.kind_of? Fixnum) ? ("#"+idx.to_s+" ") : (idx.to_s+" ")
      end
      puts "ERROR: Definition #{show}of #{user.inspect} references #{kind} id #{id}" ; exit
    end

    def id_to_s
      "stac_#{persist_pref}_#{id}"
    end

    def expand_args(val, state, args)
      return val unless val
      return val if val.kind_of? Fixnum
      return val if val.kind_of? TrueClass
      return val if val.kind_of? FalseClass

      if val.kind_of? Hash
        nval = {}
        val.each { |k, v| nval[k] = expand_args(v, state, args) }
        return nval
      end

      if val.kind_of? Array
        return val.collect { |v| expand_args(v, state, args) }
      end

      val = val.to_s if val.kind_of? Symbol

      if val.kind_of? String
        # Save a copy of the original string in case we need to report an error
        save = val.dup

        # Look for any argument substitutions in the string
        vpos = 0
        vlen = val.length
        xcnt = 0
        while subx = val.index(ARG_SUB_PREFIX, vpos)
          # Looks like an argument reference - extract the arg name
          bpos = subx + ARG_SUB_PREFIX.length
          mtch = val.match(/([A-Z_][0-9A-Z_]+)/, bpos)
          if not mtch
            puts "ERROR: invalid arg reference in #{val} at position #{subx}" ; exit
          end
          name = mtch[0]
          epos = bpos + name.length - 1

          # First, try to lowercase the name and find it in supplied "args"
          aexp = nil
          if args
            aexp = args[name.downcase]
############puts "found expansion in args  for #{name.downcase} -> #{aexp}" if aexp
            if not aexp
              aexp = args[name.downcase.to_sym]
##############puts "found expansion in args  for :#{name.downcase} -> #{aexp}" if aexp
            end
          end
          # If that doesn't work, look in the global test state
          if not aexp
            aexp = state[name]
############puts "found expansion in state for :#{name} -> #{aexp}" if aexp
            if not aexp
              puts "ERROR: reference to undefined argument #{name} in #{save}" ; exit
            end
          end
          # We have found a substitution for the argument
          if aexp.kind_of? Hash or aexp.kind_of? Array
            # Are we replacing the entire value?
            return aexp if subx == 0 and epos == val.length - 1
            aexp = aexp.inspect
          end
          aexp = aexp.to_s

          # Replace the argument reference with its value
##########puts "Replacing stac_arg[#{name}] in string #{val}"
          val[subx .. epos] = aexp
##########puts "Replaced  stac_arg[#{name}] to yield  #{val}"

          if (xcnt += 1) > 20
            puts "ERROR: limit on expansion reached in #{val}" ; exit
          end

          # Continue looking for any more argument references
          vpos = subx
        end
        return val
      end

      puts "ERROR: expand_args() called with a value of type #{val.class}" ; exit
    end

  end

  # Each of these "definition" classes needs to provide the following
  # methods:
  #
  #   initialize(data)          constructor with optional initial data
  #
  #   to_s                      return nicely formatted string representation
  #
  #   self.find_inst(id)        given an id, return matching instance (or nil)
  #
  #   find_id(id)               an instance method version of find_inst()
  #
  #   persist_pref              returns "app" / "dev" / etc.
  #
  #   record_def(srcf,data)     save definition hash (optionally checks the values)
  #
  #   check_ref(inst,args)      process a reference from another definition (which
  #                             is passed in as "inst")

  # The following class holds / processes "info" definitions
  class TestDef_Inf < TestDef_Base
    attr_accessor :exec
    def initialize(srcf, data)
      super(srcf, data)
      @exec = pull_val(:exec)
    end
    def persist_pref
      "inf"
    end
    def self.find_inst(id)
      $inf_defs[id]
    end
    def find_id(id)
      TestDef_Inf.find_inst(id)
    end
    def record_def(srcf, hash)
      $inf_defs[hash[:id]] = TestDef_Inf.new(srcf, hash)
      nil
    end
    def check_def
      return unless @data
    end
    def check_ref(inst, args)
      # UNDONE: need to check ref to inf #{@id} with args=#{args}
      return self,args
    end
    def to_s
      "Inf[#{@id}]: exec=#{@exec.inspect}"
    end

    def exec_set_var(state, info)
      var = info[:var].to_s
      val = info[:val].to_s

      # The variable might be an &ARG name
      m = var.match(/^#{ARG_SUB_PREFIX}(.*)$/)
      var = m[1] if m

######puts "Setting test state variable #{var} to #{val}"

      state[var] = val
    end

    def exec_def_var(state, info)
      var = info[:var].to_s
      val = info[:val].to_s

      # The variable might be an &ARG name
      m = var.match(/^#{ARG_SUB_PREFIX}(.*)$/)
      var = m[1] if m

######puts "Setting test state variable #{var} to #{val}"    unless state[var]
######puts "Leaving test state variable #{var} as #{state[var]}" if state[var]

      state[var] = val unless state[var]
    end

    def exec_rep_beg(state, info)
    end

    def exec_rep_end(state, info)
    end

    def create_predef1(name, exec)
      record_def("<predefined:#{name}>", { :id => name, :exec => exec })
    end

    def create_predefs
      create_predef1 "set_state" , method(:exec_set_var)
      create_predef1 "def_state" , method(:exec_def_var)
      create_predef1 "repeat_beg", method(:exec_rep_beg)
      create_predef1 "repeat_end", method(:exec_rep_end)
    end
  end

  # The following class holds / processes "app" definitions
  class TestDef_App < TestDef_Base
    attr_accessor :dir
    attr_accessor :name
    attr_accessor :crashes
    def initialize(srcf, data)
      super(srcf, data)
      if data
        @dir  = pull_val(:app_dir)
        @name = pull_val(:app_name)
      end
    end
    def persist_pref
      "app"
    end
    def self.find_inst(id)
      $app_defs[id]
    end
    def find_id(id)
      TestDef_App.find_inst(id)
    end
    def record_def(srcf, hash)
      $app_defs[hash[:id].to_s] = TestDef_App.new(srcf, hash)
      nil
    end
    def check_def
      # Make sure the app path looks legit
      dir = @data[:app_path]
      File.directory?(dir) if dir
      if dir
        if not File.directory?(dir)
          puts "FATAL: app directory \'#{dir}\' doesn't look valid" ; exit
        end
      end

      # Make sure the 'crash' value is something we recognize
      c = @data[:app_crash]
      case c
      when nil
        c = :never
      when :never, :random, :always, :explicit, :sometime, :immediate, :soon
      else
        puts "FATAL: the value \'#{c}\' is not a recognized :app_crash value" ; exit
      end
      @crashes = c
    end
    def check_ref(inst, args)
      # UNDONE: check ref to app #{@id} with #{args}
      return self,args
    end
    def get_vmc_push_args(name, args, state)
      # Set all argument defaults
      a_instances = 1
      a_path      = @dir
      a_url       = name + "." + state[:apps_URI]
      a_mem       = "128M"
      a_crash     = :never
      a_services  = []
      a_war       = nil
      a_exec_cmd  = nil
      a_framework = nil

      # Pull any overrides from the definition
      @data.each do |k, v|
        # Make sure we recognize any overrides (or issue a warning)
        case k
        when :app_insts   then a_instances = v.to_i
        when :app_mem     then a_mem       = v
        when :app_war     then a_war       = v
        when :app_path    then a_path      = v
        when :app_exec    then a_exec_cmd  = v
        when :app_fmwk    then a_framework = v
        when :app_svcs    then a_services  = v
        when :app_crash   then a_crash     = v
        end
      end

      # Look for any overrides in the "args" value
      args.each do |k, v|
        # Make sure we recognize all the overrides (or issue a warning)
        case k
        when :inst_cnt    then a_instances = v.to_i
        when :app_insts   then a_instances = v.to_i
        when :duration # ignore
        end
      end

      # Collect all the (non-nil) values and return them
      return { :path      => a_path,
               :instances => a_instances,
               :url       => a_url, # .gsub('_', '-'),
               :mem       => a_mem,
               :war       => a_war,
               :exec_cmd  => a_exec_cmd,
               :framework => a_framework,
               :services  => a_services,
               :crashes   => a_crash,
             }
    end

    def to_s
      "App[#{@id}]"
    end
  end

  # The following class holds / processes "dev" definitions
  class TestDef_Dev < TestDef_Base
    attr_accessor :acts
    def initialize(srcf, data)
      super(srcf, data)
      @acts = pull_val(:actions)
    end
    def persist_pref
      "dev"
    end
    def self.find_inst(id)
      $dev_defs[id]
    end
    def find_id(id)
      TestDef_Dev.find_inst(id)
    end
    def record_def(srcf, hash)
      $dev_defs[hash[:id]] = TestDef_Dev.new(srcf, hash)
      nil
    end
    def check_def
      # Check the 'actions' array
      @acts.each do |a|
        # Each action should have :vmc_action and optional :args
        act = a[:vmc_action]
        if not act or not act.kind_of? Symbol
          puts "FATAL: dev action \'#{act}\' is not a :VMC_xxx symbol" ; exit
        end

        begin
          acc = eval("VMC_Actions::" + act.to_s)
        rescue => err
          puts "FATAL: dev action \'#{act}\' is not a :VMC_xxx symbol" ; exit
        end

        # Replace the action symbol with its enum value
        a[:vmc_action] = acc

        # Check the arguments for any "app_def" references
        arg = a[:args]
        if arg
          # ... check arg - but how? ...
        end
      end
    end
    def check_ref(inst, args)
######puts "UNDONE: Check ref to dev action #{@id} with #{args.inspect}"
      return self,args
    end
    def grab_inst_info(args, what)
      inum = args[:inst_num]
      imin = args[:inst_min]
      imax = args[:inst_max]
      if inum
        # Better not have min/max if we have num
        if imin or imax
          puts "ERROR: redundant instance info in \'#{what}\' vmc action" ; exit
        end
        args.delete(:inst_num)
      else
        if not imin or not imax
          puts "ERROR: missing instance info in \'#{what}\' vmc action" ; exit
        end
        args.delete(:inst_min)
        args.delete(:inst_max)
      end
      return inum,imin,imax
    end
    def self.output_user_reg(inst, clock, state) # used to start the "vmc" sequence
      args = {
               :email    => "#{state[:ac_user_name]}@vmware.com",
               :password => "notneeded"
             }
      ActionQueue.enqueue_dev(inst, clock, state, VMC_Actions::VMC_ADD_USER, nil, args)
    end
    def output_action(clock, state, args, queue)
      tdur = 0
      @acts.each do |a|
        # Make sure instance count defaults to 1 for "push app" actions
        args[:app_insts] = 1 if a[:vmc_action] == VMC_Actions::VMC_PUSH_APP and not args[:app_insts]

        # Expand the arguments (if any) for this action
        aexp = expand_args(a[:args], state, args)

########puts "Output dev action vmc #{VMC_Actions.action_to_s(a[:vmc_action]).ljust(12, ' ')} with #{aexp.inspect}"

        # Grab an app name argument, if present
        anam = TestDef_Base.pull_val_from(aexp, :app_name)

        # Check for an "app_def" argument
        adef = aexp[:app_def]
        idef = nil
        if adef
          # The "app_def" value should be a ref to a defined app
          idef, bsid = TestDef_Base.parse_def_id(adef.to_s)

          # Make sure we can find a matching app definition
          idef = idef.find_id(bsid) if idef
          if not idef
            puts "ERROR: reference to unknown app_def #{adef}" ; exit
          end
          aexp.delete(:app_def)
        end

        # Apply the jitter and time scaling factor to the :duration value
        dur = args[:duration] || aexp[:duration]
        if dur
          dur = ActionQueue.action_duration(dur * state[:time_scaling])

          # Store the updated duration value in the argument hash
          aexp[:duration] = dur

          # Update the overall duration value
          tdur += dur
        end

        # See what type of action we're supposed to perform
        act = a[:vmc_action]
        case act

        when VMC_Actions::VMC_PUSH_APP
          # There better be a reference to the app we're supposed to push
          if not idef
            puts "ERROR: missing app_def in 'vmc push' action" ; exit
          end

          # We better have an app name
          if not anam
            puts "ERROR: missing app name" ; exit
          end

          # Ask the 'app' class for the values we need to push
          varg = idef.get_vmc_push_args(anam, aexp, state)

          # Ready to create the "vmc push" command
          ActionQueue.enqueue_dev(self, clock, state, act, anam, varg)

          # Record the URL for the app in the global state
          state["@_APP_"+anam] = varg[:url]

          # Mark the definition as consumed by this command
          idef = nil

          # get_vmc_push_args() already flagged anything it doesn't recognize
          aexp = nil

        when VMC_Actions::VMC_DEL_APP
          ActionQueue.enqueue_dev(self, clock, state, act, anam, aexp)

        when VMC_Actions::VMC_CHK_APP
          ActionQueue.enqueue_dev(self, clock, state, act, anam, aexp)

        when VMC_Actions::VMC_UPD_APP
          adup = aexp.dup
          adup[:app_def] = idef
          ActionQueue.enqueue_dev(self, clock, state, act, anam, adup)

          # Mark the definition as used by this command
          idef = nil

        when VMC_Actions::VMC_ADD_SVC
          ActionQueue.enqueue_dev(self, clock, state, act, anam, aexp)
          aexp.delete(:services)

        when VMC_Actions::VMC_DEL_SVC
          ActionQueue.enqueue_dev(self, clock, state, act, anam, aexp)
          aexp.delete(:services)

        when VMC_Actions::VMC_INSTCNT
          inst = TestDef_Base.pull_val_from(aexp, :inst_cnt).to_i
          if aexp[:rel_icnt]
            aexp.delete(:rel_icnt)
            inst = (inst > 0) ? ("+" + inst.to_s) : inst.to_s
          end
          adup = aexp.dup
          adup[:inst_cnt] = inst
          ActionQueue.enqueue_dev(self, clock, state, act, anam, adup)

          aexp.delete(:random) if aexp[:random]

        when VMC_Actions::VMC_CRASHES
          ActionQueue.enqueue_dev(self, clock, state, act, anam, aexp)

        when VMC_Actions::VMC_CRSLOGS
          # We should have "inst_num" or "inst_min/max"
          inum,imin,imax = grab_inst_info(aexp, "crash logs")
          adup = aexp.dup
          if inum
            adup[:inst_num] = inum
            ActionQueue.enqueue_dev(self, clock, state, act, anam, adup)
          else
            adup[:inst_min] = imin
            adup[:inst_max] = imax
            ActionQueue.enqueue_dev(self, clock, state, act, anam, adup)
          end

        when VMC_Actions::VMC_APPLOGS
          # We should have "inst_num" or "inst_min/max"
          inum,imin,imax = grab_inst_info(aexp, "app logs")
          adup = aexp.dup
          if inum
            adup[:inst_num] = inum
            ActionQueue.enqueue_dev(self, clock, state, act, anam, adup)
          else
            adup[:inst_min] = imin
            adup[:inst_max] = imax
            ActionQueue.enqueue_dev(self, clock, state, act, anam, adup)
          end

          aexp.delete(:random) if aexp[:random]

        when VMC_Actions::VMC_DEL_APP
          ActionQueue.enqueue_dev(self, clock, state, act, anam, aexp)

        else
          @@logger.error("ERROR: unknown or unhandled vmc action #{VMC_Actions.action_to_s(a[:vmc_action])} #{aexp.inspect}") ; exit
        end

        if idef
          @@logger.warn("ignoring app def #{idef.inspect} reference in dev action #{@id}")
        end
      end

      # Return the total duration estimate to the caller
      tdur
    end
    def to_s
      "Dev[#{@id}]: actions[#{@acts.length}]"
    end
  end

  # The following class holds / processes "use" definitions
  class TestDef_Use < TestDef_Base
    attr_accessor :use_acts
    def initialize(srcf, data)
      super(srcf, data)
      if data
        @use_act_count = pull_val(:use_actions)
      end
    end
    def persist_pref
      "use"
    end
    def self.find_inst(id)
      $use_defs[id]
    end
    def find_id(id)
      TestDef_Use.find_inst(id)
    end
    def record_def(srcf, hash)
      $use_defs[hash[:id]] = TestDef_Use.new(srcf, hash)
      nil
    end
    def check_def
      return unless @data

      @use_act_count.each do |a|
        # UNDONE: check validity of HTTP action #{a.inspect} in #{srcf}
      end
    end
    def check_ref(inst, args)
      if not args[:duration]
        puts "ERROR: reference to use \'#{@id}\' from #{inst.srcf} missing :duration"; exit
      end
      return self,args
    end
    def append_act(use, state, args)
    end
    def output_action(clock, state, args, queue)
      # The argument list must always include an app reference [ISSUE: should we use the :use_app hash key instead of a hard-wired arg name?]
      name = args[:app_name]
      if not name
        puts "ERROR: in #{srcf} use arguments #{args.inspect} missing app name" ; exit
      end
      name = expand_args(name, state, nil)

      # The app name better be in the test state or we won't know the URL
      url = state["@_APP_"+name]
      if not url
        puts "ERROR: app #{name} has no URL recorded - did you push it?" ; exit
      end

      # Get hold of the load and duration values
      hld = args[:http_load]
      hps = args[:http_ms_pause] || 10000
      dur = args[:duration ]

      # Apply the jitter and time scaling factor to the :duration value
      dur = ActionQueue.action_duration(dur * state[:time_scaling]) if dur

      # Grab the "http_args" if any are present
      hargs = args[:http_args]

      # Ready to process the action list
      @use_act_count.each do |a|
        # Is the action a "simple" action or a "mix" of use actions ?
        mix = a[:use_mix]
        if mix and mix.kind_of? Array
          mxs = []
          tot = 0
          mix.each do |m|
            # Perform argument substitution on the mix entry
            mx = expand_args(m, state, args)

            # Check the :fraction values and all that
            if not mx[:fraction]
              puts "FATAL: no :fraction value found in use_mix #{mx.inspect}"
              exit 1
            end
            tot += mx[:fraction].to_i

            # Append the expanded mix entry to the array
            mxs << mx
          end
          # Make sure the fraction values add up to 100%
          if tot != 100
            puts "FATAL: sum of :fraction values is #{tot} instead of 100"
            exit 1
          end

          # Append this as a single "mix" action
          use = { :mix => mxs }
          act = :http_mix
        else
          use = expand_args(a, state, args)
##########@@logger.debug("        [#{STAC::act_prefix(clock, state)}] >>use #{url} as #{@id} with #{us.inspect}")
          act = TestDef_Base.pull_val_from(use, :action).to_sym
        end

        # Fill in the rest of the arguments and append to the action queue
        use[:app_url      ] = url
        use[:app_name     ] = name
        use[:http_load    ] = hld
        use[:http_ms_pause] = hps
        use[:duration     ] = dur
        use[:http_args    ] = hargs if hargs
        ActionQueue.enqueue_use(self, clock, state, act, use)
      end

      # Return the total duration estimate to the caller
      dur ? dur : 0
    end
    def to_s
      "Use[#{@id}]"
    end
  end

  # The following class holds / processes "scenario" definitions
  class TestDef_Scn < TestDef_Base
    attr_accessor :acts, :tot_time
    def initialize(srcf, data)
      super(srcf, data)
      @acts = pull_val(:actions)

      # Some scenarios never terminate
      @forever = nil
      if @data and @data[:no_stop]
        @forever = true
        @data.delete(:no_stop)
      end

      # Some scenarios should not be stretched in time
      @fixed_time = nil
      if @data and @data[:fixed_time]
        @fixed_time = true
        @data.delete(:fixe_time)
      end
    end
    def persist_pref
      "scn"
    end
    def self.find_inst(id)
      $scn_defs[id]
    end
    def find_id(id)
      TestDef_Scn.find_inst(id)
    end
    def record_def(srcf, hash)
      $scn_defs[hash[:id]] = TestDef_Scn.new(srcf, hash)
      nil
    end
    def check_def
      return unless @data

      # We'll collect the processed entries in a new array
      nact = []

      # Compute an overall running time estimate
      tdur = 0

      @acts.each_with_index do |a, x|
        # Each action must have at least an action id, plus optional args
        id, args = TestDef_Base.pull_action_id(a.dup)
        if not id
          puts "ERROR: scenario entry #{a.inspect} in #{srcf} is missing \':action_id=>nil\' entry" ; exit
        end

        # Compute total overall running time (but watch out for infinities)
        dur = args[:duration]
        if dur == INFINITY
          tdur = dur.to_f
        elsif dur
          if tdur == INFINITY
            puts "ERROR: scenario entry #{a.inspect} in #{srcf} follows a never-ending entry" ; exit
          end
          # Do we need to randomize the time value?
          if dur < 0
            # Use a random value between 'dur/2' and 'dur'
            dur /= -2.0
            dur = dur + rand(dur)
            # Update the negative value in the args with the new value
            args[:duration] = dur
          end
          tdur += dur.to_f
        end

        # Let the definition class process the usage of its own id
        nact << TestDef_Base.check_def_use(self, id, x, args)
      end

      # Record and log the overall running time estimate
      @tot_time = tdur

      @@logger.debug("Duration of scenario %-34s: #{tdur}" % srcf)

      # Replace the old actions table with the new one
      @acts = nact
    end
    def check_ref(inst, args)
      puts "FATAL: TestDef_Scn.check_ref() should never be called, right?" ; exit
    end
    def to_s
      "Scn[#{@id}]"
    end
    def stretch_time(new_time)
      return if @fixed_time
      # Pass 1: add up the durations of all the stretchable actions
      # Pass 2: stretch actions
      sfactor = nil
      2.times do |pass|
        tot_stm = 0
        @acts.each do |a|
          next if a.length < 2
          act = a[0]
          arg = a[1]

          # Get the duration value and skip if missing or infinite
          dur = arg[:duration]
          next if not dur or dur == INFINITY

          # Don't bother with "dev" actions that are supposed to be fast
          next if act.kind_of? TestDef_Dev and dur <= 1

          # Pass 1: simply total up the stretchable actions
          # Pass 2: stretch duration values
          arg[:duration] = dur = dur * sfactor if pass > 0
          tot_stm += dur
        end
        @tot_time = tot_stm

        # Bail if nothing to stretch or the time is close enough
        return if tot_stm == 0 or tot_stm * 1.1 >= new_time
        sfactor = new_time.to_f / tot_stm
      end
    end
  end

  # The following class holds / processes "test mix" definitions
  class TestDef_Mix < TestDef_Base
    attr_accessor :mixes
    def initialize(srcf, data)
      super(srcf, data)
    end
    def persist_pref
      "mix"
    end
    def self.find_inst(id)
      $mix_defs[id]
    end
    def find_id(id)
      TestDef_Mix.find_inst(id)
    end
    def record_def(srcf, hash)
      $mix_defs[hash[:id]] = TestDef_Mix.new(srcf, hash)
      nil
    end
    def check_def
      return unless @data

      @@logger.debug("Checking 'test mix' definition from #{srcf}:")

      # We'll collect all the test mixes in a simple array
      @mixes = []

      # The only top-level value we're interested in is :test_def
      tdef = @data[:test_def]
      tdef.each_with_index do |mix, mnum|
        mcnt = mix[:count].to_i
        mdef = mix[:mix]
        if not mcnt or not mdef
          puts "ERROR: mix definition #{mnum} missing :count or :mix" ; exit
        end

        @@logger.debug("   test mix #{mnum}: #{mcnt} times")

        # Collect the scenario lists in an array; make sure they add up to 100%
        scns = []
        pcts = 0
        mdef.each_with_index do |sdef, snum|

          # Check for a :fraction value and record it
          spct = sdef[:fraction]
          if spct
            spct = spct.to_i
          else
            if mdef.length != 1
              puts "ERROR: scenario table #{snum} of test mix #{mnum} has no :fraction" ; exit
            end
            spct = 100
          end
          pcts += spct

          @@logger.debug("      scenario table #{snum}: fraction=#{spct}")

          # Check the :tests table
          tsts = sdef[:tests]
          if not tsts
            puts "ERROR: scenario table #{snum} of test mix #{mnum} has no :tests" ; exit
          end

          # Collect the scenario table in an array
          stab = []
          tsts.each_with_index do |test, tnum|
            test = test.to_s unless test.kind_of? String

            # Each entry should start with "$SCN_USE_<scenario_name>"
            mtch = test.match(/^\$#{SCN_REF_PREFIX}([a-z]+[a-z0-9_]*)[\($]/)
            if not mtch
              puts "ERROR: scenario #{tnum} in table #{snum} of test mix #{mnum} looks bogus -- #{test}" ; exit
            end

            # Grab the scenario name from the match, and get any remaining text
            scnn = mtch[1]
            rest = test[mtch[0].length - 1 .. -1]

            # Make sure the scenario has been defined
            scen = TestDef_Scn.find_inst(scnn)
            if not scen
              puts "ERROR: scenario #{tnum} in table #{snum} of test mix #{mnum} references unknown scenario #{scnn}" ; exit
            end

            # Check the rest of the string for (optional) arguments
            if rest != ""
              # We should have an app argument
              if rest[0,1] != '(' or rest[-1,1] != ')'
                puts "ERROR: expected (:stac_app_xxx) instead of #{rest}}" ; exit
              end

              # There might be a single app or a list of apps (or arg values)
              apps = []
              rest[1 .. -2].split(",").each do |app|
                # Strip any leading whitespace and ":"if present
                app.strip!
                app = app[1 .. -1] if app[0,1] = ':'

                # Check for any arguments to be passed into the scenario
                m = app.match(/(\w+)\s*=>\s*(.*)/)
                if m and m.length == 3
                  # Check for "special" scenario argument(s)
                  case m[1]
                  when "init_insts"
                    begin
                      ic = Integer(m[2])
                    rescue
                      puts "ERROR: init_insts requires an integer, found #{m[2]}" ; exit
                    end
                    apps << { :iic => ic }
                  when "repeats"
                    begin
                      rc = Integer(m[2])
                    rescue
                      puts "ERROR: repeats requires an integer, found #{m[2]}" ; exit
                    end
                    apps << { :rep => rc }
                  else
                    # Pass a generic "key => val" thing to the scenario
                    apps << { :def => [ m[1], m[2] ] }
                  end
                else
                  # Make sure we have an app reference
                  idef, bsid = TestDef_Base.parse_def_id(app)
                  idef = idef.find_id(bsid) if idef
                  if not idef or not idef.kind_of? TestDef_App
                    puts "ERROR: invalid / undefined id #{app} in #{rest} from #{srcf}" ; exit
                  end
                  apps << { :app => idef }
                end
              end
              rest = apps
            end

            @@logger.debug("        test #{tnum}: #{scen.to_s}#{rest}")

            # Append an entry to the table of scenario components
            stab << { :scen => scen, :args => rest }
          end

          # Append an entry to the table of scenarios for the current user
          scns << { :frac => spct, :scns => stab }
        end

        # Make sure the fractions added up to 100%
        if pcts != 100
          puts "ERROR: scenario fractions of test mix #{mnum} add up to #{pcts} instead of 100" ; exit
        end

        # Append an entry to the table of mixes
        @mixes << { :count => mcnt, :mix => scns }
      end
    end
    def check_ref(inst, args)
      puts "FATAL: TestDef_Mix.check_ref() should never be called, right?" ; exit
    end
    def to_s
      "Mix[#{@id}]"
    end
  end

  # Factory instances for all the definition types
  FactInst_App = TestDef_App.new("<none>", nil)
  FactInst_Dev = TestDef_Dev.new("<none>", nil)
  FactInst_Use = TestDef_Use.new("<none>", nil)
  FactInst_Scn = TestDef_Scn.new("<none>", nil)
  FactInst_Mix = TestDef_Mix.new("<none>", nil)
  FactInst_Inf = TestDef_Inf.new("<none>", nil)

  # A table that holds the various definition factories
  Def_table = [ FactInst_App,
                FactInst_Dev,
                FactInst_Use,
                FactInst_Scn,
                FactInst_Mix,
                FactInst_Inf ]

  # Table of "persistence prefix" values for all the definition flavors
  Def_prefs = Def_table.collect { |i| i.persist_pref }

  # Table that maprsx from "persistence prefix" to a definition class instance
  Def_mapps = {}
  Def_table.each { |i| Def_mapps[i.persist_pref.to_s] = i }

  ############################################################################
  #
  #   The 'StressTestRunner' class loads up the app / dev / etc. definitions,
  #   and then executes the test mix(es) selected on the command line.
  #
  class StressTestRunner

    attr_accessor :logger
    attr_accessor :config

    AC_HOMEDIR = File.join(File.dirname(__FILE__), '..')

    def initialize(_config, _logger)
      @config = _config
      @logger = _logger

      # Lock and counter for inventing unique index values
      @@index_lock = Mutex.new
      @@index_next = 0

      # Lock for max. clock value
      @maxclk_lock = Mutex.new
    end

    def self.new_unique_index
      @@index_lock.synchronize do
        ret = @@index_next ; @@index_next += 1
        return ret
      end
    end

    def self.max_unique_index
      @@index_next
    end

    # Load all definition files in the given directory
    def load_def_dir(dir)
      Dir.glob(File.join(dir, "*.stac")).each { |f| load_def_file(f); }
    end

    # Collect an argument string passed to a scenario reference
    def grab_scn_arg(str, pos)
      return 0 unless str[pos, 1] == "("

      # Ready to collect the (argument) string
      beg = pos
      lps = lbs = lcs = 0

      # Simple scan: note pair nesting and strings, nothing else
      while pos < str.length
        case str[pos,1]
        when ')'
          # Return the length of the matched string to the caller
          return pos + 1 - beg if lps == 1 and lbs == 0 and lcs == 0
          lps -= 1
        when '('
          lps += 1

        when '['
          lbs += 1
        when ']'
          lbs -= 1

        when '{'
          lcs += 1
        when '}'
          lcs -= 1

        end
        pos += 1
      end
    end

    # A little helper that expands any references to built-in functions
    def replace_builtins(str)
      vpos = 0
      while fpos = str.index("&", vpos)
        # Check for names of the built-in functions
        repl = nil

        # Check for a scenario reference
        if str[fpos+1, SCN_REF_PREFIX.length] == SCN_REF_PREFIX
          # First grab the scenario name
          m = str.match(/\w+\s*/, fpos + 9)
          if m
            sn = m[0]
            bp = fpos + 9 + sn.length
            # We have the scenario name, now collect the argument string (if any)
            as = grab_scn_arg(str, bp)
            # Wrap the "&USE_SCN_xxxx(arg)" thing in quotes
            olen = SCN_REF_PREFIX.length + 1 + sn.length + as
            str[fpos, olen] = '"$' + str[fpos+1, olen - 1] + '"'
############puts "Scenario argument replaced: #{str[fpos, olen+10]}"
          end
        else
          # For now we just hard-wire some names here (because we're lazy)
          repl = "&instance_count",9 if str[fpos+1,9] == "INST_CNT("
          repl = "&random"        ,4 if str[fpos+1,4] == "RND("

          # Did we have a match?
          if repl
            # Replace the "&name(" part with the new name
            str[fpos, repl[1]] = repl[0]
          end
        end

        # Continue looking for more replacements in the rest of the string
        vpos = fpos + 1
      end
      str
    end

    def __builtin(name, *args)
      name + args.to_s
    end

    def verify_target_URL(host)
      begin
        resp = HTTPClient.send("get", host + "/info")

        # Make sure the reply looks reasonable
        if not resp or resp.status >= 400
          puts "FATAL: response from #{host}/info had status #{resp.status}"
          return true
        end

        # Try to JSON the response
        info = JSON.parse(resp.content)

        # Anything else we should check here?
        if info['name'] != "vcap"
          puts "FATAL: response from #{host}/info doesn't look right: #{resp.content[0..30]} ..."
          return true
        end

        return false
      rescue => e
        puts "FATAL: could not get response from #{host}/info - error #{e.inspect}"
        return true
      end
    end

    def log_health(which, comp, lastx, status, resp="")
      if status.to_i >= 400 or resp.chomp == ""
        # ISSUE: should we log failures?
        return
      end

      # Ignore useless reports (/healthz says nothing useful right now)
      return if resp.chomp == "ok"

      # The response should be in JSON, but be careful
      begin
        resp = JSON.parse(resp)
      rescue => e
        @logger.warn("The #{which} value was not JSON or something: #{resp}")
        return
      end

      # Get hold of the last set of values we logged (if any)
      last = comp[:last][lastx] || {}

      # Collect the status into a single string to log all at once
      rep = ""
      resp.each do |key,val|
        next if key == "uptime" and not $xdetail
        if last[key] != val
          rep += "    %-24s -> #{val.inspect}\n" % key
          last[key] = val
        end
      end
      comp[:last][lastx] = last
      @logger.info("/#{which} status for #{comp[:type]} #{comp[:host]}:\n" + rep) if rep != ""
    end

    def components_poll
      return if @components.empty?

      @logger.info("Updating health status for all components ...")

      @components.each_value do |component|
        mtch = component[:host].match(/(.*):(.*)/)
        host = mtch[1]
        port = mtch[2].to_i

        cred = component[:credentials]

        begin
          if false
            url = "http://#{component[:host]}/healthz"
            http_hltz = EM::HttpRequest.new(url).get :head => { "authorization" => component[:credentials] }
            http_hltz.callback { log_health("healthz", component, 0, http_hltz.response_header.status, http_hltz.response) }
            http_hltz.errback  { log_health("healthz", component, 0, 503) }
          else
            resp = nil
            Net::HTTP.start(host, port) {|http|
              req = Net::HTTP::Get.new('/healthz')
              req.basic_auth cred[0], cred[1] if cred
              resp = http.request(req)
            }
            log_health("healthz", component, 0, 200, resp.body)
          end
        rescue => e
          log_health("healthz", component, 0, 503, e.inspect)
        end

        begin
          if false
            url = "http://#{component[:host]}/varz"
            http_varz = EM::HttpRequest.new(url).get :head => { "authorization" => component[:credentials] }
            http_varz.callback { log_health("varz", component, 1, http_varz.response_header.status, http_varz.response) }
            http_varz.errback  { log_health("varz", component, 1, 503) }
          else
            resp = nil
            Net::HTTP.start(host, port) {|http|
              req = Net::HTTP::Get.new('/varz')
              req.basic_auth cred[0], cred[1] if cred
              resp = http.request(req)
            }
            log_health("varz", component, 1, 200, resp.body)
          end
        rescue => e
          log_health("varz", component, 1, 503, e.inspect)
        end

      end
    end

    def component_discover(msg)
      begin
        info = Yajl::Parser.parse(msg, :symbolize_keys => true)
      rescue
        info = nil
      end

      # If we have nothing or are missing type/uuid/host, it's no good
      if not info or not info[:type] or not info[:uuid] or not info[:host]
        @logger.error("Received non-comformant reply for component discover: #{msg}")
        return
      end

      # Have we seen this component already?
      old = @components[info[:uuid]]
      if old
        # This is old news - just make sure we copy over any :last values
        last = old[:last]
      else
        # Log the discovery of this component
        @logger.info("Component #{info[:host]} #{info[:type]}")
        # We don't have any :last values yet
        last = [nil,nil]
      end

      # Use the new info while making sure we preserve any 'last' values
      info[:last] = last
      @components[info[:uuid]] = info
    end

    # Load a definition file contents and record it in the appropriate table
    def load_def_file(file)
      ex_proc = lambda do |msg|
        puts "ERROR: Problem reading definition file #{file}: #{msg}"
        exit
      end

      @logger.debug("Loading definition file #{file}")

      # Try to load and evaluate the contents of the file
      data = nil
      begin
        # Read the file into a variable
        cont = File.read(file)
        # Process any built-in function calls
        cont = replace_builtins(cont)
        # Process any argument substitutions
        cont = cont.gsub(/&([A-Z_]+)/, ":#{ARG_SUB_PREFIX}\\1")
        data = eval(cont)
      rescue Exception => err
        ex_proc.call("#{err}")
      end

      @logger.debug("Loaded  definition file #{file} ...")

      # The result better be a hash
      ex_proc.call("contents is not a hash") unless data.kind_of? Hash

      # Get hold of the "id" value
      id = data[:id].to_s

      # Check the id prefix to determine the type of definition
      idef, id = TestDef_Base.parse_def_id(id)

      # Bail if the id didn't parse OK
      ex_proc.call(id) unless idef

      # Replace the id with the "naked" id in the hash
      data[:id] = id

      # Check and record the data in the appropriate table
      err = idef.record_def(file, data)
      ex_proc.call(err) if err
    end

    # Main entry point: load definitions and run a test mix (or mixes)
    def run_test
      logger.info("Starting stress test run")

      # Create the pre-defined "info" actions
      FactInst_Inf.create_predefs

      # Get hold of the URL for the target AC
      target = @config[:target_AC]

  ##  puts
  ##  puts "Cmdline: #{ARGV.inspect}"
  ##  puts "Config : #{@config.inspect}"
  ##  puts

      # Load all definitions (given by config file and command line)
      @config['def_dirs' ].each { |d| load_def_dir(d)  } if @config['def_dirs' ]
      @config['def_files'].each { |f| load_def_file(f) } if @config['def_files']

  ##  puts "AppDefs 1: #{$app_defs.inspect}"
  ##  puts "DevDefs 1: #{$dev_defs.inspect}"
  ##  puts "UseDefs 1: #{$use_defs.inspect}"
  ##  puts "ScnDefs 1: #{$scn_defs.inspect}"
  ##  puts "MixDefs 1: #{$mix_defs.inspect}"
  ##  puts

      # Verify that the data looks reasonable and hook up refs
      $app_defs.each { |x,y| TestDef_App.find_inst(x).check_def() }
      $dev_defs.each { |x,y| TestDef_Dev.find_inst(x).check_def() }
      $use_defs.each { |x,y| TestDef_Use.find_inst(x).check_def() }
      $scn_defs.each { |x,y| TestDef_Scn.find_inst(x).check_def() }
      $mix_defs.each { |x,y| TestDef_Mix.find_inst(x).check_def() }
      $inf_defs.each { |x,y| TestDef_Inf.find_inst(x).check_def() }

  ##  puts "AppDefs 2: #{$app_defs.inspect}"
  ##  puts "DevDefs 2: #{$dev_defs.inspect}"
  ##  puts "UseDefs 2: #{$use_defs.inspect}"
  ##  puts "ScnDefs 2: #{$scn_defs.inspect}"
  ##  puts "MixDefs 2: #{$mix_defs.inspect}"
  ##  puts

      # Create an instance of the executor class
      @executor = STAC::StressTestExec.new(config, logger, target)

      # Enable tracing if desired
      #@executor.trace = $verbose ? true : false

      # Do a quick sanity check on the target URL (unless this is a dry run)
      if not @config['dry_run_plan']
        turl = "http://" + target
        if verify_target_URL(turl)
          puts "Please check your target URL and Cloud Foundry setup"
          exit 1
        end

        # Make sure we can login using the supplied creds
        au = @config['ac_admin_user']
        ap = @config['ac_admin_pass']

        begin
          begin
            @executor.register_internal(turl, au, ap)
          rescue
          end
          atok = @executor.login_internal(turl, au, ap)
        rescue => e
          if not e.kind_of? RuntimeError or e.to_s != "login failed"
            puts "ERROR: Exception from login: #{e.to_s}"
          end
          puts "ERROR: could not login as admin user \'#{au}\', please check the creds"
          exit 1
        end

        # Create the basic authorization header
        auth = { 'AUTHORIZATION' => atok.to_s }

        # Verify that we can create a user, then login and and proxy that user
        test_user = (@config['unique_stacid'] || "") + "ac-test-probe-user@vmware.com"
        test_pass = "random"
        have_user = false

        begin
          # Create a user account with a name that hopefully is unique to us
          begin
            @executor.register_internal(turl, test_user, test_pass)
          rescue => e
            @logger.error("Could not register a test user, please check remote admin: #{e.inspect}")
            exit 1
          end

          # Make sure we delete this user no matter what happens below
          have_user = true

          # Login the user we just created
          begin
            @executor.login_internal(turl, test_user, test_pass)
          rescue => e
            @logger.error("Could not login a test user, please check remote admin: #{e.inspect}")
            exit 1
          end

          # Create an auth header with the user as being proxied
          aprx = auth.dup
          aprx['PROXY-USER'] = test_user

          # Try to do something (anything) with the user proxied
          begin
            alst = @executor.get_apps_internal(turl + "/apps", aprx)
            # get_apps_internal() returns an array when things work correctly
            throw "bad response" unless alst and alst.kind_of? Array
          rescue => e
            @logger.error("Could not proxy a test user, please make sure #{au} is an admin: #{e.inspect}")
            exit 1
          end

          # Done with the test user - the 'ensure' clause below will clean up
        ensure
          begin
            @executor.delete_user_internal(turl, test_user, auth) if have_user
          rescue => e
            puts "WARNING: could not delete test user account #{test_user} - #{e.inspect}"
          end
        end
      end

      # Figure out which test mix we're supposed to run
      test = @config['what_to_run']
      if test
        # Lookup the test(s) in the table
        tdef = []
        test.each do |key,val|
          tchk = $mix_defs[key]
          if not tchk
            puts "ERROR: The specified test mix \'#{test}\' is not defined"
            exit
          end
          tdef << tchk
        end
      else
        # No test specified - if there is exactly one test defined, use it
        if $mix_defs.length != 1
          puts "ERROR: please select a test mix to run via command-line options;"
          puts "       here are the available test mixes that have been defined:"
          puts
          $mix_defs.each do |id,df|
            puts "       #{id}"
          end
          exit
        end
        tdef = [ $mix_defs[0] ]
      end

      # Figure out the base URI for apps
      ha = target.split('.')
      ha.shift
      @apps_uri = ha.join('.')

      # Initialize the global test state / environment
      global_state = {
                       :target_AC    => target,
                       :apps_URI     => @apps_uri,
                       :time_scaling => @config['time_scaling'] ? @config['time_scaling'] : 1
                     }

      @max_clock = 0

      # Compute an estimate of the total number of users / scenarios; also,
      # equalize scenario running times (if enabled).
      #
      # We do this in two passes - the first pass computes the duration of
      # the longest-running scenario, and the second pass then stretches
      # any scenarios that are too short to match the longest one.
      max_sctm = 0
      tot_usrs = 0
      tot_scns = 0
      2.times do |pass|
        tot_usrs = tot_scns = 0
        tdef.each do |mdef|
          mdef.mixes.each do |userset|
            uc = userset[:count]
            userset[:mix].each do |mixdef|
              # Add to the running user / scenario totals
              frac = mixdef[:frac] ? mixdef[:frac].to_i : 100
              scns = mixdef[:scns]
              tot_scns += scns.length * (uc * frac / 100)

              # That's all unless we're equalizing
              next unless @config['equalize_sctm']

              # Check all the scenario durations
              scns.each do |scn|
                scen = scn[:scen]
                sctm = scen.tot_time

                # Don't bother to scale infinity
                next if sctm == INFINITY

                # In the first pass we simply compute the max duration
                if pass == 0
                  max_sctm = sctm if max_sctm < sctm
                else
                  # Second pass: stretch scenario if appropriate
                  scen.stretch_time(max_sctm) if sctm < max_sctm
                end
              end
            end
            tot_usrs += uc
          end
        end

        @logger.debug("Longest scenario is #{max_sctm} seconds") if pass == 0

        # Don't bother with a second pass if we're not equalizing
        break unless @config['equalize_sctm']
      end

      @logger.info("Test defines #{tot_usrs} users and #{tot_scns} user/scenario combos")
              puts("Test defines #{tot_usrs} users and #{tot_scns} user/scenario combos")

      # We'll set the following flag if we have any infinite scenarios
      @have_inf = false

      # Generate action sequences for each test mix we're supposed to run
      usrs = 0
      tdef.each_with_index do |mdef, mnum|
        logger.debug("Starting test mix \'#{mdef.id}\' from #{mdef.srcf}")

        # Make a unique copy of the test state / environment
        state = global_state.dup
        state[:test_mix_num] = mnum
        state[:test_mix_def] = mdef

        logger.debug("    [#{STAC::act_prefix(0, state)}] >>vmc target #{target}")

        # For each user set, invoke their mixes
        ucnt = 0
        mdef.mixes.each_with_index do |userset, usernum|
          # Make a unique copy of the state for this userset
          ustat = state.dup
          ustat[:user_set_num] = usernum
          ustat[:user_set_def] = userset

          run_user_set(ustat, tot_usrs, tot_scns, userset, ucnt)

          ucnt += userset[:count]
          usrs += userset[:count]
        end

        logger.debug("Finished test mix \'#{mdef.id}\'")
      end

      # If at least one scenario is infinite, we better have a time limit
      if @have_inf and not @config['max_runtime']
        puts "ERROR: infinite scenarios present and no time limit set" ; exit
      end

      # At this point all the action queues should be filled and ready
      queue = ActionQueue.merge_queues

      # Get the health reporting subsystem started, if desired
      if @config['health_intvl'] > 0 and @config['nats_server'] and not @config['dry_run_plan']
        @nats_inited = false
        @components = {}
        Thread.new do
          nats = @config['nats_server']
          nats = "nats://" + nats unless nats[0, 7] == "nats://"
          begin
            logger.info("Logging into NATS server \'#{nats}\'")
            NATS.start(:uri => nats) do
              # Tell the main thread that we're connected now
              @nats_inited = true

              # Watch for new components
              NATS.subscribe('vcap.component.announce') do |msg|
                component_discover(msg)
              end

              # Keep endpoint around for subsequent pings
              inbox = NATS.create_inbox
              NATS.subscribe(inbox) { |msg| component_discover(msg) }

              # Ping for status/discovery immediately and then at timer ticks
              ping = proc { NATS.publish('vcap.component.discover', '', inbox) }
              ping.call
              EM.add_periodic_timer(30) { ping.call }

              EM.add_timer(@config['health_intvl']) do
                components_poll
                EM.add_periodic_timer(@config['health_intvl']) { components_poll }
              end
            end
          rescue => e
            puts "FATAL: could not connect to NATS server #{nats} -- #{e.inspect}"
            exit!
          end
        end
        # Wait for NATS to get connected before proceeding
        while not @nats_inited; sleep(0.1) ; end
      end

      logger.info("Estimated ending clock: #{@max_clock} sec")
             puts("Estimated ending clock: #{@max_clock} sec")

      # Ready to start executing the actions in the queue
      begin
        @executor.execute_plan(queue, @config['dry_run_plan'],
                                      usrs,
                                      StressTestRunner.max_unique_index)
      rescue => e
        logger.error("Plan execution threw #{e.inspect}\n#{e.backtrace.join("\n")}")
      end

      logger.info("STAC test run ended (#{usrs} total devs)")
      exit
    end

    # Run the specified user set (defined within a test mix)
    def run_user_set(state, tot_usrs, tot_scns, userset, usrnbs)
      # Get hold of the total user count and the mix table
      usercnt = userset[:count]
      usermix = userset[:mix]

      logger.debug("  Run user set #{state[:user_set_num]}: #{usercnt} users total")

      # Invent AC users based on the total count and percentage values
      usrsdn = 0
      usermix.each_with_index do |mixdef, mixnum|
        frac = mixdef[:frac]
        scns = mixdef[:scns]

        # Compute the actual number of users we need
        users = (usercnt / 100.0 * frac).to_i

        # If this is the last set, make sure the overall count will match
        users = (usercnt - usrsdn) if mixnum == usermix.length - 1

        logger.debug("    user set: #{users.to_s.ljust(3, ' ')} users to run #{scns.length} scenario(s)")

        # Process the chosen number of users (with the same scenario table)
        users.times do
          run_user_mix(state.dup, tot_usrs, tot_scns, usrnbs + usrsdn, scns)
          usrsdn  += 1
        end
      end
      (puts "FATAL: someone screwed up counting users!" ; exit) unless usrsdn == usercnt
    end

    # Run the specified scenario table under a dev / AC user we make up
    def run_user_mix(state, tot_usrs, tot_scns, usernum, scns)
      # Reccord the user number
      state[:ac_user_num] = usernum

      # Invent and register a unique AC user
      user_name = (@config['unique_stacid'] || "") + "ac_test_user_%04u" % usernum
      state[:ac_user_name] = user_name

      @logger.debug("      [#{STAC::act_prefix(0, state)}] >>vmc register user #{user_name}")

      # Create a queue for this user's actions
      state[:action_queue] = q = Queue.new

      # Add the queue to the global queue list
      ActionQueue.record_queue(q)

      # Start each user off at a slightly randomized time
      clock = rand(@config['clock_jitter'])

      # If we have a lot of users/scenarios, stagger their starts
      clock *= tot_scns / 10 if tot_scns > 10 and @config['stagger_scen']

      logger.debug("Starting clock at #{clock} for U#{usernum}")

      # Start the queue off with a "vmc register <user>" action
      TestDef_Dev.output_user_reg(FactInst_Dev, clock, state)

      # Make sure the user registration happens first
      clock += 1

      # Process each mix entry under this AC user
      scns.each_with_index do |scn, num|
        run_scenario(state.dup, scn, num, clock)
      end
    end

    # Expand one or more (nested) repeat blocks; recursive method
    def expand_repeat(rep, clock, &out)
      start = clock
      rep[:reps].times do
        rep[:body].each do |a|
          clock += out.call(a[:action][0], a[:action][1]) if a[:action]
          clock = expand_repeat(a[:nested], clock, &out)  if a[:nested]
        end
      end
      # Return the updated clock as the value
      clock
    end

    def run_scenario(state, scn, snum, init_clock)
      # Get hold of the scenario and the arguments (if any)
      scen = scn[:scen]
      args = scn[:args]

      # Save the scenario # in the state / environment
      state[:ac_scen_num] = snum

      # Make up a unique string to avoid collisions
      unum = state[:ac_user_num]
      uniq = "#{unum}-#{snum}"

      # Set the application name
      appn = (@config['unique_stacid'] || "") + "test-app-" + uniq
      state["APPNAME"] = appn
      state[:app_name] = appn

      # Process any arguments that were passed in to the scenario
      args.each do |a|
        # A few arguments are "known" and need special handling
        if a[:app] and a[:app].kind_of? TestDef_App
          state["APPDEF"] = a[:app].id_to_s
          next
        end
        if a[:iic] and a[:iic].kind_of? Fixnum
          state["APPINSTS"] = a[:iic]
          next
        end
        if a[:rep] and a[:rep].kind_of? Fixnum
          state["REPEATS" ] = a[:rep]
          next
        end
        if a[:def] and a[:def].kind_of? Array and a[:def].length == 2
          ad = a[:def]
          state[ad[0]] = ad[1]
          @logger.debug("Setting scenario argument \'#{ad[0]}\' to \'#{ad[1]}\'")
          next
        end
        @logger.warn("Unrecognized scenario argument #{a.inspect} ignored")
      end

      # Run through the scenario steps
      logger.debug("      Start scenario #{snum} for u#{unum}: #{scen}")

      # Assign this user/scenario a unique integer index
      state[:uniquex] = StressTestRunner.new_unique_index

      # Initialize a unique clock for this user/scenario
      clock = init_clock + rand(@config['clock_jitter']) / 10

      logger.debug("Starting clock at #{clock} for U#{state[:ac_user_num]}/S#{snum}")

      # Get hold of the queue for this user
      actq = state[:action_queue]

      # We're not in a "repeat" block (yet)
      rep_outer = nil

      # Process each action in the scenario and output use/dev actions
      scen.acts.each_with_index do |a,x|
        # Make sure each action looks OK (i.e. array of 1 or 2 elems)
        if not a.kind_of? Array or a.length < 1 or a.length > 2
          puts "FATAL: this should never happen, action is not [x] or [x,y]" ; exit
        end

        # Extract the action and (optional) argument(s)
        act = a[0]
        arg = (a.length == 2) ? a[1] : nil

        # We execute "info" actions immediately
        if act.kind_of? TestDef_Inf
          # UNDONE: we need to synchronize/lock on "state", right?
          case act.id
          when "repeat_beg"
            begin
              cnt = state['REPEATS']
              cnt = Integer(cnt)
              throw "no way" unless cnt > 0
            rescue Exception
              puts "FATAL: repeat count is #{cnt}, expected a positive number" ; exit
            end

            # Create a new "repeat" descriptor
            rep_dsc = {
                        :outer  => rep_outer,     # parent or nil
                        :reps   => cnt,           # how many times
                        :body   => [],            # repeated action list
                        :id     => a[1][:rep_id]  # for begin/end matching
                      }

            # Add the repeat to the parent's body (if nested)
            rep_outer[:body] << { :nested => rep_dsc } if rep_outer

            # We have a new "outermost" descriptor
            rep_outer = rep_dsc
          when "repeat_end"
            # Make sure we have a repeat section with a matching ID
            if not rep_outer
              puts "FATAL: repeat end without matching begin" ; exit
            end
            if a[1][:rep_id] and a[1][:rep_id] != rep_outer[:id]
              puts "FATAL: repeat end id #{a[1][:rep_id]} differs from current section id #{rep_outer[:id]}" ; exit
            end

            # Did we just end a nested repeat, or a top-level one?
            if rep_outer[:outer]
              # We have a parent so just pop the current section
              rep_outer = rep_outer[:outer]
            else
              # For repeat expansion we do the same thing as each "normal"
              # iteration of this entire loop, i.e. the code should match
              # the output code in the "else" part below (but note that
              # instead of "a,x" we have "b,y" here).
              clock = expand_repeat(rep_outer, clock) do |b,y|
                # Note that we return the updated clock as the value
                clock + b[0].output_action(clock, state, (b.length == 2) ? b[1] : nil, actq)
              end
              rep_outer = nil
            end
          else
            act.exec.call(state, arg)
          end
        elsif rep_outer
          # We're collecting a repeat section - add the action to the body
          rep_outer[:body] << { :action => [a,x] }
        else
          # Non-info test action: expand args and send to the output queue
          dur = act.output_action(clock, state, arg, actq)

          # Adjust the clock
          clock += dur
        end
      end
      logger.debug("      Ended scenario #{snum} for U#{unum}")

      # Log the ending clock value and update max if higher
      if clock == INFINITY
        @have_inf = true
      else
        clock = (clock + 0.5).to_i
        logger.debug("End clock for U#{unum}/S#{snum}: #{clock}")
        @maxclk_lock.synchronize {
          @max_clock = clock if @max_clock < clock
        }
      end
    end

    def abort_test
      @executor.abort_test
    end
  end

  class StressTestAC < Sinatra::Base

    VERSION        = 0.007
    INFO_STRING    = "Stress Tester for AppCloud (version #{VERSION})"
    DEFAULT_CONFIG = 'config/stac.yml'
    WORKER_THREADS = 16

    attr_accessor :logger

    class << self

      def int_option(name, opt)
        begin
          i = Integer(opt)
          return i if i >= 0
        rescue
        end
        puts "FATAL: option \'--#{name}\' requires positive integer value, found \'#{opt}\'"
        exit!
      end

      def flt_option(name, opt)
        begin
          f = Float(opt)
          return f if f >= 0
        rescue
        end
        puts "FATAL: option \'--#{name}\' requires positive float value, found \'#{opt}\'"
        exit!
      end

      def parse_options_and_config
        return @config if @config

        # The following values can be changed via the command line
        config_file   = File.join(File.dirname(__FILE__), DEFAULT_CONFIG)
        log_file      = nil
        status_port   = nil
        thin_logging  = nil
        log_level     = nil
        dry_run_plan  = nil
        max_runtime   = nil
        clock_jitter  = nil
        ac_admin_user = nil
        ac_admin_pass = nil
        no_http_uses  = nil
        time_scaling  = nil
        thread_count  = nil
        update_freq   = nil
        unique_stacid = nil
        equalize_sctm = nil
        stagger_scen  = nil
        log_rsrc_use  = nil
        nats_server   = nil
        pause_at_end  = nil
        log_end_stat  = nil
        health_intvl  = 0
        more_defiles  = []
        more_defdirs  = []
        run_this_mix  = []

        # Parse any command-line options
        options = OptionParser.new do |opts|

          opts.banner = 'Usage: stac [OPTIONS] ac_address'

          opts.on("-c", "--config FILE", "Configuration File") do |opt|
            config_file = opt
          end

          opts.on("-l", "--logfile FILE", "Log file (default=stdout)") do |opt|
            log_file = opt
          end

          opts.on("-L", "--log_level LVL", "Logging level") do |opt|
            log_level = opt
          end

          opts.on("-d", "--defdir PATH", "Add definition directory") do |opt|
            more_defdirs << opt
          end

          opts.on("-f", "--defile FILE", "Add definition file") do |opt|
            more_defiles << opt
          end

          opts.on("-i", "--identifier UNIQUE_ID", "Set user/app name prefix to allow multiple STAC's to coexist") do |opt|
            unique_stacid = opt
          end

          opts.on("-j", "--clock_jitter PCT", "Set clock jitter in percent (0..100)") do |opt|
            clock_jitter = int_option("clock_jitter", opt)
          end

          opts.on("-w", "--update_freq SECS", "Time between warm'n'fuzzy updates in seconds") do |opt|
            update_freq  = flt_option("update_freq", opt)
          end

          opts.on("-m", "--max_runtime SECS", "Cap running time (seconds)") do |opt|
            max_runtime = int_option("max_runtime", opt)
          end

          opts.on("-p", "--port PORTNUM", "Change status port number") do |opt|
            status_port = int_option("port", opt)
          end

          opts.on("-t", "--thin_logging", "Enable Thin logging") do |opt|
            thin_logging = true
          end

          opts.on("-u", "--dry_run", "Pretend to execute test plan.") do |opt|
            dry_run_plan = true
          end

          opts.on("-v", "--verbose", "Display extra detail (mostly for debugging)") do |opt|
            $verbose = true
          end

          opts.on("-q", "--quiet", "Minimal console output") do |opt|
            $bequiet = true
          end

          opts.on("-n", "--newgen", "Use newgen CLI interfaces") do |opt|
            $newgen = true
          end

          opts.on("-x", "--extra_detail", "Log more detail about app crashes and such") do |opt|
            $xdetail = true
          end

          opts.on("-s", "--equalize_scen_time", "Equalize scenario running time") do |opt|
            equalize_sctm = true
          end

          opts.on("-S", "--stagger_scen", "Stagger scenarios") do |opt|
            stagger_scen = true
          end

          opts.on("-e", "--pause_at_end", "Pause before cleanup to enable inspection") do |opt|
            pause_at_end = true
          end

          opts.on("-k", "--log_end_stat", "Log detailed ending state of the system") do |opt|
            log_end_stat = true
          end

          opts.on("-r", "--run_mix MIXNAME", "Run specified test mix") do |opt|
            run_this_mix << opt
          end

          opts.on("--ac_admin_user USERNAME", "Set AppCloud admin user login") do |opt|
            ac_admin_user = opt
          end

          opts.on("--ac_admin_pass PASSWORD", "Set AppCloud admin user password") do |opt|
            ac_admin_pass = opt
          end

          opts.on("--time-scale SCALE", "Scale all time duration values") do |opt|
            time_scaling = flt_option("scale", opt)
          end

          opts.on("--thread-count NUM", "Number of executor threads") do |opt|
            thread_count = int_option("thread-count", opt)
          end

          opts.on("--no_http_uses", "Don't issue HTTP use actions") do |opt|
            no_http_uses = opt
          end

          opts.on("--nats_server HOST", "Specify user:pass@host:port of nats server") do |opt|
            nats_server = opt
          end

          opts.on("--health_intvl SECS", "How often to log health stats (0=disabled)") do |opt|
            health_intvl = int_option("health_intvl", opt)
          end

          opts.on("-U", "--log_resource_use SECS", "Log our resource usage with given frequency") do |opt|
            log_rsrc_use = int_option("log_resource_use", opt)
          end

          opts.on("-h", "--help", "Help") do
            puts opts
            exit
          end
        end
        options.parse!(ARGV)

        # We should have one argument at this point - the target AC
        if ARGV.length != 1
          puts "FATAL: expected one argument (URL for target AC) but found #{ARGV.length}"
          exit
        end

        # Load the config file
        begin
          @config = File.open(config_file) do |f|
            YAML.load(f)
          end
        rescue => e
          puts "Could not read configuration file:  #{e}"
          exit
        end

        # Save any command line overrides in @config
        @config['status_port'  ] = status_port   if status_port
        @config['thin_logging' ] = thin_logging  if thin_logging
        @config['log_file'     ] = log_file      if log_file
        @config['what_to_run'  ] = run_this_mix  if run_this_mix.length > 0
        @config['log_level'    ] = log_level     if log_level
        @config['max_runtime'  ] = max_runtime   if max_runtime
        @config['clock_jitter' ] = clock_jitter  if clock_jitter
        @config['dry_run_plan' ] = dry_run_plan  if dry_run_plan
        @config['ac_admin_user'] = ac_admin_user if ac_admin_user
        @config['ac_admin_pass'] = ac_admin_pass if ac_admin_pass
        @config['no_http_uses' ] = no_http_uses  if no_http_uses
        @config['time_scaling' ] = time_scaling  if time_scaling
        @config['thread_count' ] = thread_count  if thread_count
        @config['update_freq'  ] = update_freq   if update_freq
        @config['unique_stacid'] = unique_stacid if unique_stacid
        @config['equalize_sctm'] = equalize_sctm if equalize_sctm
        @config['stagger_scen' ] = stagger_scen  if stagger_scen
        @config['nats_server'  ] = nats_server   if nats_server
        @config['health_intvl' ] = health_intvl  if health_intvl
        @config['log_rsrc_use' ] = log_rsrc_use  if log_rsrc_use
        @config['pause_at_end' ] = pause_at_end  if pause_at_end
        @config['log_end_stat' ] = log_end_stat  if log_end_stat

        # Can't log health info without a nats server
        if @config['health_intvl'] > 0 and not @config['nats_server']
          puts "WARNING: health logging disabled without 'nats' server"
          @config['health_intvl'] = 0
        end

        # Pull in the new client stuff only if necessary
        require '../vmc/lib/vmc/client' if $newgen

        # Stash the target URL in the config hash as well
        @config[:target_AC] = ARGV[0]

        # Load any definitions from given directories and individual files
        if more_defdirs.length > 0
          load_defdirs = @config['def_dirs'] || []
          @config['def_dirs' ] = load_defdirs + more_defdirs
        end

        if more_defiles.length > 0
          load_defiles = @config['def_files'] || []
          @config['def_files'] = load_defiles + more_defiles
        end

        return @config
      end # method parse_options_and_config

    end # class << self

    def initialize
      super
      @logger = @@logger
    end

    configure do

      @config = nil

      # Grab the configuration (and parse command-line options if necessary)
      config = StressTestAC.parse_options_and_config

      # Initialize logger - either with a file or STDOUT
      log_file = config['log_file']
      log_file = STDOUT unless log_file and log_file != "" and log_file != "STDOUT"
      @@logger = Logger.new(log_file)

      # Set logging level
      @@logger.level = case config['log_level']
        when 'DEBUG' then Logger::DEBUG
        when 'INFO'  then Logger::INFO
        when 'WARN'  then Logger::WARN
        when 'ERROR' then Logger::ERROR
        when 'FATAL' then Logger::FATAL
        when nil     then Logger::UNKNOWN
        else
          puts "FATAL: invalid logging level value #{config['log_level']}"
          exit
      end

      TestDef_Base.set_logger(@@logger)

      # Set the clock jitter value (if present)
      ActionQueue.set_logger(@@logger)
      ActionQueue.set_jitter(@config['clock_jitter']) if @config['clock_jitter']

      # Create pidfile (and ensure we delete it when done)
      pidfile = config['pid']
      begin
        begin
          FileUtils.mkdir_p(File.dirname(pidfile))
        rescue => e
          logger.fatal "Can't create pid directory, exiting: #{e}"
        end
        File.open(pidfile, 'w') { |f| f.puts "#{Process.pid}" }

        # This is just a hack
        local_ip = "127.0.0.1"

        # Set a bunch of values in our instance
        sinatra_keys = {
          :logger => @@logger,
          :local_host => "#{local_ip}:#{config['status_port']}",
          :port => config['status_port'],
          :logging => false,
          :proxy => config['proxy'],
          :no_proxy => config['no_proxy'],
        }
        sinatra_keys.each {|k,v| StressTestAC.set(k, v) }

        # Announce we are starting up
        logger.info("Starting #{INFO_STRING}")
        logger.debug("PID: #{Process.pid}")

        # Create an instance of the test runner class
        runner = StressTestRunner.new(config, logger)

        exit_proc = proc do
          logger.info("AC Stress Tester exiting..")
          runner.abort_test
        end

        stop_proc = proc do
          exit_proc.call
          exit
        end

        ['TERM', 'INT'].each { |sig| trap(sig, stop_proc) }

        # Start EM Thread
        Thread.new do
          EM.threadpool_size = WORKER_THREADS
          logger.debug("Using #{EM.threadpool_size} worker threads")

          EM.error_handler do |err|
            logger.error "Eventmachine problem, #{err}"
            logger.error("#{err.backtrace.join("\n")}")
          end
        end

        # This doesn't really belong here, but for now ...
        runner.run_test

        exit_proc.call
      ensure
        FileUtils.rm_f(pidfile) if pidfile
      end

    end # configure do .. end

    get '/' do
      INFO_STRING
    end

  end # class StressTestAC

end # module STAC

config = STAC::StressTestAC.parse_options_and_config
server = Thin::Server.new('0.0.0.0', config['status_port']) do
  use Rack::CommonLogger if config['thin_logging']
  map "/" do
    run STAC::StressTestAC
  end
end
server.threaded = true
server.start!

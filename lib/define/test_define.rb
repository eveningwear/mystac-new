
module STAC
  
  ARG_SUB_PREFIX = "__STAC_ARG_"    # marks arg substitutions

  SCN_REF_PREFIX = "USR_SCN_"       # scenarios are referenced via this string

  $app_defs = {}
  $dev_defs = {}
  $usr_defs = {}
  $scn_defs = {}
  $mix_defs = {}
  $inf_defs = {}

  # The base for the various classes that hold definition info:
  class TestDef_Base

    attr_accessor :srcf
    attr_accessor :data
    attr_accessor :id
    attr_accessor :desc
    attr_accessor :pref

    def initialize(srcf, data, pref)

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
      @pref = pref
    end
    
    def persist_pref
      @pref
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
      unless parts && parts.length == 3
        return nil, "type is not recognized in #{name}" 
      end

      # Make sure the "id" is known
      idef = Def_mapps[parts[1]]
      #puts(parts[1])#Add by jacky
      unless idef
        return nil, "type \'#{parts[1]}\' of 'id' value \'#{name}\' is not recognized"
      end

      # Everything looks good, return the instance and the "naked" id
      return idef, parts[2]
    end

    def id_to_s
      "stac_#{persist_pref}_#{id}"
    end

    def expand_args_new(data, state)
      return data unless data
      return data if data.kind_of? Fixnum
      return data if data.kind_of? TrueClass
      return data if data.kind_of? FalseClass

      if data.kind_of? Hash
        ndata = {}
        data.each do |key, value|
          ndata[key] = expand_args_new(value, state)
        end
        return ndata
      end

      if data.kind_of? Array
        @@logger.error("ERROR: unknown parameter: #{data.to_s}") ; exit
      end

      if data.kind_of? Symbol
        data = data.to_s.gsub(/#{ARG_SUB_PREFIX}([A-Z_]+)/, "\\1")
      end
      
      value = state[data] 
      value = state[data.to_s] unless value
      value = state[data.to_sym] unless value
      value = data unless value #Need some enhancement here
      unless value
        @@logger.error("ERROR: value missed for argument: #{data}") 
        exit 
      end
      value
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
        valDup = val.dup

        # Look for any argument substitutions in the string
        vpos = 0
        vlen = val.length
        xcnt = 0
        while subx = val.index(ARG_SUB_PREFIX, vpos)
          # Looks like an argument reference - extract the arg name
          bpos = subx + ARG_SUB_PREFIX.length
          matchArray = val.match(/([A-Z_][0-9A-Z_]+)/, bpos)
          if not matchArray
            puts "ERROR: invalid arg reference in #{val} at position #{subx}" ; exit
          end
          name = matchArray[0]
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
              puts "ERROR: reference to undefined argument #{name} in #{valDup}" ; exit
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
  #   record_def(srcf,data)     save definition hash (optionally checks the values)

  # The following class holds / processes "info" definitions
  class TestDef_Inf < TestDef_Base
    attr_accessor :exec
    def initialize(srcf, data)
      super(srcf, data, "inf")
      @exec = pull_val(:exec)
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
    def makeup_def
      return unless @data
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
      super(srcf, data, "app")
      if data
        @dir  = pull_val(:app_dir)
        @name = pull_val(:app_name)
      end
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
    def makeup_def
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
      super(srcf, data, "dev")
      @acts = pull_val(:actions)
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
    def makeup_def
      # Check the 'actions' array
      @acts.each do |action|
        # Each action should have :vmc_action and optional :args
        act = action[:vmc_action]
        if not act or not act.kind_of? Symbol
          puts "FATAL: dev action \'#{act}\' is not a :VMC_xxx symbol" ; exit
        end

        begin
          acc = eval("VMC_Actions::" + act.to_s)
        rescue => err
          puts "FATAL: dev action \'#{act}\' is not a :VMC_xxx symbol" ; exit
        end

        # Replace the action symbol with its enum value
        action[:vmc_action] = acc

        # Check the arguments for any "app_def" references
        arg = action[:args]
        if arg
          # ... check arg - but how? ...
        end
      end
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
    def self.create_user_register_action(inst, clock, state) # used to start the "vmc" sequence
      args = {
               :email    => "#{state[:ac_user_name]}@vmware.com",
               :password => "notneeded"
             }
      ActionQueue.enqueue_dev(inst, clock, state, VMC_Actions::VMC_ADD_USER, nil, args)
    end
    def caculate_duration(clock, state, args, queue)
      durationSum = 0
      @acts.each do | action |
        # Make sure instance count defaults to 1 for "push app" actions
        args[:app_insts] = 1 if action[:vmc_action] == VMC_Actions::VMC_PUSH_APP and not args[:app_insts]

        # Expand the arguments (if any) for this action
        # argsExp = expand_args(action[:args], state, args)
        argsExp = expand_args_new(action[:args], state)

########puts "Output dev action vmc #{VMC_Actions.action_to_s(action[:vmc_action]).ljust(12, ' ')} with #{argsExp.inspect}"

        # Grab an app name argument, if present
        appName = TestDef_Base.pull_val_from(argsExp, :app_name)

        # Check for an "app_def" argument
        appDef = argsExp[:app_def]
        idef = nil
        if appDef
          # The "app_def" value should be a ref to a defined app
          idef, bsid = TestDef_Base.parse_def_id(appDef.to_s)

          # Make sure we can find a matching app definition
          idef = idef.find_id(bsid) if idef
          if not idef
            puts "ERROR: reference to unknown app_def #{appDef}" ; exit
          end
          argsExp.delete(:app_def)
        end

        # Apply the jitter and time scaling factor to the :duration value
        duration = args[:duration] || argsExp[:duration]
        if duration
          duration = ActionQueue.action_duration(duration * state[:time_scaling])

          # Store the updated duration value in the argument hash
          argsExp[:duration] = duration

          # Update the overall duration value
          durationSum += duration
        end

        # See what type of action we're supposed to perform
        vmcAction = action[:vmc_action]

        case vmcAction
        when VMC_Actions::VMC_PUSH_APP
          # There better be a reference to the app we're supposed to push
          if not idef
            puts "ERROR: missing app_def in 'vmc push' action" ; exit
          end

          # We better have an app name
          if not appName
            puts "ERROR: missing app name" ; exit
          end

          # Ask the 'app' class for the values we need to push
          vmcArg = idef.get_vmc_push_args(appName, argsExp, state)

          # Ready to create the "vmc push" command
          ActionQueue.enqueue_dev(self, clock, state, vmcAction, appName, vmcArg)

          # Record the URL for the app in the global state
          state["@_APP_" + appName] = vmcArg[:url]

          # Mark the definition as consumed by this command
          idef = nil

          # get_vmc_push_args() already flagged anything it doesn't recognize
          argsExp = nil

        when VMC_Actions::VMC_DEL_APP
          ActionQueue.enqueue_dev(self, clock, state, vmcAction, appName, argsExp)

        when VMC_Actions::VMC_CHK_APP
          ActionQueue.enqueue_dev(self, clock, state, vmcAction, appName, argsExp)

        when VMC_Actions::VMC_UPD_APP
          argsExpTmp = argsExp.dup
          argsExpTmp[:app_def] = idef
          ActionQueue.enqueue_dev(self, clock, state, vmcAction, appName, argsExpTmp)

          # Mark the definition as used by this command
          idef = nil

        when VMC_Actions::VMC_ADD_SVC
          ActionQueue.enqueue_dev(self, clock, state, vmcAction, appName, argsExp)
          argsExp.delete(:services)

        when VMC_Actions::VMC_DEL_SVC
          ActionQueue.enqueue_dev(self, clock, state, vmcAction, appName, argsExp)
          argsExp.delete(:services)

        when VMC_Actions::VMC_INSTCNT
          inst = TestDef_Base.pull_val_from(argsExp, :inst_cnt).to_i
          if argsExp[:rel_icnt]
            argsExp.delete(:rel_icnt)
            inst = (inst > 0) ? ("+" + inst.to_s) : inst.to_s
          end
          argsExpTmp = argsExp.dup
          argsExpTmp[:inst_cnt] = inst
          ActionQueue.enqueue_dev(self, clock, state, vmcAction, appName, argsExpTmp)

          argsExp.delete(:random) if argsExp[:random]

        when VMC_Actions::VMC_CRASHES
          ActionQueue.enqueue_dev(self, clock, state, vmcAction, appName, argsExp)

        when VMC_Actions::VMC_CRSLOGS
          # We should have "inst_num" or "inst_min/max"
          inum, imin, imax = grab_inst_info(argsExp, "crash logs")
          argsExpTmp = argsExp.dup
          if inum
            argsExpTmp[:inst_num] = inum
            ActionQueue.enqueue_dev(self, clock, state, vmcAction, appName, argsExpTmp)
          else
            argsExpTmp[:inst_min] = imin
            argsExpTmp[:inst_max] = imax
            ActionQueue.enqueue_dev(self, clock, state, vmcAction, appName, argsExpTmp)
          end

        when VMC_Actions::VMC_APPLOGS
          # We should have "inst_num" or "inst_min/max"
          inum,imin,imax = grab_inst_info(argsExp, "app logs")
          argsExpTmp = argsExp.dup
          if inum
            argsExpTmp[:inst_num] = inum
            ActionQueue.enqueue_dev(self, clock, state, vmcAction, appName, argsExpTmp)
          else
            argsExpTmp[:inst_min] = imin
            argsExpTmp[:inst_max] = imax
            ActionQueue.enqueue_dev(self, clock, state, vmcAction, appName, argsExpTmp)
          end

          argsExp.delete(:random) if argsExp[:random]

        when VMC_Actions::VMC_DEL_APP
          ActionQueue.enqueue_dev(self, clock, state, vmcAction, appName, argsExp)

        else
          @@logger.error("ERROR: unknown or unhandled vmc action #{VMC_Actions.action_to_s(action[:vmc_action])} #{argsExp.inspect}") ; exit
        end

        if idef
          @@logger.warn("ignoring app def #{idef.inspect} reference in dev action #{@id}")
        end
      end

      # Return the total duration estimate to the caller
      durationSum
    end
    def to_s
      "Dev[#{@id}]: actions[#{@acts.length}]"
    end
  end

  # The following class holds / processes "use" definitions
  class TestDef_Usr < TestDef_Base
    attr_accessor :usr_acts
    def initialize(srcf, data)
      super(srcf, data, "usr")
      if data
        @usr_acts = pull_val(:usr_actions)
      end
    end
    def self.find_inst(id)
      $usr_defs[id]
    end
    def find_id(id)
      TestDef_Usr.find_inst(id)
    end
    def record_def(srcf, hash)
      $usr_defs[hash[:id]] = TestDef_Usr.new(srcf, hash)
      nil
    end
    def makeup_def
      return unless @data

      @usr_acts.each do |action|
        # UNDONE: check validity of HTTP action #{a.inspect} in #{srcf}
      end
    end
    def append_act(use, state, args)
    end
    def caculate_duration(clock, state, args, queue)
      # The argument list must always include an app reference [ISSUE: should we use the :use_app hash key instead of a hard-wired arg name?]
      appName = args[:app_name]
      if not appName
        puts "ERROR: in #{srcf} use arguments #{args.inspect} missing app name" ; exit
      end
      #appName = expand_args(appName, state, nil)
      appName = expand_args_new(appName, state)

      # The app name better be in the test state or we won't know the URL
      url = state["@_APP_" + appName]
      if not url
        puts "ERROR: app #{appName} has no URL recorded - did you push it?" ; exit
      end

      # Get hold of the load and duration values
      hld = args[:http_load]
      hps = args[:http_ms_pause] || 10000
      duration = args[:duration ]

      # Apply the jitter and time scaling factor to the :duration value
      duration = ActionQueue.action_duration(duration * state[:time_scaling]) if duration

      # Grab the "http_args" if any are present
      hargs = args[:http_args]

      # Ready to process the action list
      @usr_acts.each do |action|
        # Is the action a "simple" action or a "mix" of use actions ?
        usrMix = action[:usr_mix]
        if usrMix and usrMix.kind_of? Array
          usrMixNew = []
          percentageSum = 0
          usrMix.each do |useDef|
            # Perform argument substitution on the mix entry
            #mixArgsExp = expand_args(useDef, state, args)
            mixArgsExp = expand_args_new(useDef, state)

            # Check the :fraction values and all that
            if not mixArgsExp[:fraction]
              puts "FATAL: no :fraction value found in usr_mix #{mx.inspect}"
              exit 1
            end
            percentageSum += mixArgsExp[:fraction].to_i

            # Append the expanded mix entry to the array
            usrMixNew << mixArgsExp
          end
          # Make sure the fraction values add up to 100%
          if percentageSum != 100
            puts "FATAL: sum of :fraction values is #{percentageSum} instead of 100"
            exit 1
          end

          # Append this as a single "mix" action
          use = { :mix => usrMixNew }
          act = :http_mix
        else
          use = expand_args(action, state, args)
          use1 = expand_args_new(action, state)
##########@@logger.debug("        [#{act_prefix(clock, state)}] >>use #{url} as #{@id} with #{us.inspect}")
          act = TestDef_Base.pull_val_from(use, :action).to_sym
        end

        # Fill in the rest of the arguments and append to the action queue
        use[:app_url      ] = url
        use[:app_name     ] = appName
        use[:http_load    ] = hld
        use[:http_ms_pause] = hps
        use[:duration     ] = duration
        use[:http_args    ] = hargs if hargs
        ActionQueue.enqueue_use(self, clock, state, act, use)
      end

      # Return the total duration estimate to the caller
      duration ? duration : 0
    end
    def to_s
      "Use[#{@id}]"
    end
  end

  # The following class holds / processes "scenario" definitions
  class TestDef_Scn < TestDef_Base
    attr_accessor :acts, :tot_time
    def initialize(srcf, data)
      super(srcf, data, "scn")
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
    def makeup_def
      return unless @data

      # We'll collect the processed entries in a new array
      newact = []

      # Compute an overall running time estimate
      durationSum = 0

      @acts.each_with_index do |action, x|
        # Each action must have at least an action id, plus optional args
        id, args = seperate_id_with_arg(action.dup)
        if not id
          puts "ERROR: scenario entry #{a.inspect} in #{srcf} is missing \':action_id=>nil\' entry" ; exit
        end

        # Compute total overall running time (but watch out for infinities)
        duration = args[:duration]
        if duration == INFINITY
          durationSum = duration.to_f
        elsif duration
          if durationSum == INFINITY
            puts "ERROR: scenario entry #{a.inspect} in #{srcf} follows a never-ending entry" ; exit
          end
          # Do we need to randomize the time value?
          if duration < 0
            # Use a random value between 'duration/2' and 'duration'
            duration /= -2.0
            duration = duration + rand(duration)
            # Update the negative value in the args with the new value
            args[:duration] = duration
          end
          durationSum += duration.to_f
        end

        # Let the definition class process the usage of its own id
        newact << makeup_action(id, x, args)
      end

      # Record and log the overall running time estimate
      @tot_time = durationSum

      @@logger.debug("Duration of scenario %-34s: #{durationSum}" % srcf)

      # Replace the old actions table with the new one
      @acts = newact
    end
    def to_s
      "Scn[#{@id}]"
    end
    
    # Check a definition reference - usually just dispatches to the appropriate subclass
    def makeup_action(id, idx, args = nil)
      idef, bsid = TestDef_Base.parse_def_id(id.to_s)
      if idef
        ichk = idef.find_id(bsid)
        return ichk, args
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
      puts "ERROR: Definition #{show}of #{usage.inspect} references #{kind} id #{id}" ; exit
    end
    
    #The data passed is an Action definied in Scenario
    def seperate_id_with_arg(data)
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

    def stretch_time(new_time)
      return if @fixed_time
      # Pass 1: add up the durations of all the stretchable actions
      # Pass 2: stretch actions
      sfactor = nil
      2.times do |pass|
        tot_stm = 0
        @acts.each do |action|
          next if a.length < 2
          act = action[0]
          arg = action[1]

          # Get the duration value and skip if missing or infinite
          duration = arg[:duration]
          next if not duration or duration == INFINITY

          # Don't bother with "dev" actions that are supposed to be fast
          next if act.kind_of? TestDef_Dev and duration <= 1

          # Pass 1: simply total up the stretchable actions
          # Pass 2: stretch duration values
          arg[:duration] = duration = duration * sfactor if pass > 0
          tot_stm += duration
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
    attr_accessor :testMixes
    def initialize(srcf, data)
      super(srcf, data, "mix")
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
    def makeup_def
      return unless @data

      @@logger.debug("Checking 'test mix' definition from #{srcf}:")

      # We'll collect all the test mix in a simple array
      @testMixes = []

      # The only top-level value we're interested in is :testMixes
      testMixArray = @data[:test_mixes]
      testMixArray.each_with_index do |testMixDef, testMixIndex|
        userCount = testMixDef[:count].to_i
        testMix = testMixDef[:test_mix]
        if not userCount or not testMix
          puts "ERROR: mix definition #{testMixIndex} missing :count or :mix" ; exit
        end

        @@logger.debug("   test mix #{testMixIndex}: #{userCount} times")

        # Collect the scenario lists in an array; make sure they add up to 100%
        testMixNew = []
        percentageSum = 0
        testMix.each_with_index do |scnMixDef, scnMixIndex|

          # Check for a :fraction value and record it
          subPercentage = scnMixDef[:fraction]
          if subPercentage
            subPercentage = subPercentage.to_i
          else
            if testMix.length != 1
              puts "ERROR: scenario table #{scnMixIndex} of test mix #{testMixIndex} has no :fraction" ; exit
            end
            subPercentage = 100
          end
          percentageSum += subPercentage

          @@logger.debug("      scenario table #{scnMixIndex}: fraction=#{subPercentage}")

          # Check the :scn_mix table
          scnMix = scnMixDef[:scn_mix]
          if not scnMix
            puts "ERROR: scenario table #{scnMixIndex} of test mix #{testMixIndex} has no :scn_mix" ; exit
          end

          # Collect the scenario table in an array
          scnMixNew = []
          scnMix.each_with_index do |scnDef, scnIndex|
            scnDef = scnDef.to_s unless scnDef.kind_of? String

            # Each entry should start with "$SCN_USE_<scenario_name>"
            matchArray = scnDef.match(/^\$#{SCN_REF_PREFIX}([a-z]+[a-z0-9_]*)[\($]/)
            if not matchArray
              puts "ERROR: scenario #{scnIndex} in table #{scnMixIndex} of test mix #{testMixIndex} looks bogus -- #{scnDef}" ; exit
            end

            # Grab the scenario name from the match, and get any remaining text
            scnId = matchArray[1]
            scnArgs = scnDef[matchArray[0].length - 1 .. -1]

            # Make sure the scenario has been defined
            scnInst = TestDef_Scn.find_inst(scnId)
            if not scnInst
              puts "ERROR: scenario #{scnIndex} in table #{scnMixIndex} of test mix #{testMixIndex} references unknown scenario #{scnId}" ; exit
            end

            # Check the rest of the string for (optional) arguments
            if scnArgs != ""
              # We should have an app argument
              if scnArgs[0,1] != '(' or scnArgs[-1,1] != ')'
                puts "ERROR: expected (:stac_app_xxx) instead of #{scnArgs}}" ; exit
              end

              # There might be a single app or a list of apps (or arg values)
              apps = []
              scnArgs[1 .. -2].split(",").each do | appRef |
                # Strip any leading whitespace and ":"if present
                appRef.strip!
                appRef = appRef[1 .. -1] if appRef[0,1] = ':'

                # Check for any arguments to be passed into the scenario
                m = appRef.match(/(\w+)\s*=>\s*(.*)/)
                if m and m.length == 3 
		  #Currently I don't think this branch will be reached (Comments Added by Jacky)
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
                  idef, bsid = TestDef_Base.parse_def_id(appRef)
                  idef = idef.find_id(bsid) if idef
                  if not idef or not idef.kind_of? TestDef_App
                    puts "ERROR: invalid / undefined id #{appRef} in #{scnArgs} from #{srcf}" ; exit
                  end
                  apps << { :app => idef }
                end
              end
              scnArgs = apps
            end

            @@logger.debug("        test #{scnIndex}: #{scnInst.to_s}#{scnArgs}")

            # Append an entry to the table of scenario components
            scnMixNew << { :scn => scnInst, :args => scnArgs }
          end

          # Append an entry to the table of scenarios for the current user
          testMixNew << { :fraction => subPercentage, :scn_mix => scnMixNew }
        end

        # Make sure the fractions added up to 100%
        if percentageSum != 100
          puts "ERROR: scenario fractions of test mix #{testMixIndex} add up to #{percentageSum} instead of 100" ; exit
        end

        # Append an entry to the table of mix
        @testMixes << { :count => userCount, :test_mix => testMixNew }
      end
    end
    def to_s
      "Mix[#{@id}]"
    end
  end

  
  # Factory instances for all the definition types
  FactInst_App = TestDef_App.new("<none>", nil)
  FactInst_Dev = TestDef_Dev.new("<none>", nil)
  FactInst_Usr = TestDef_Usr.new("<none>", nil)
  FactInst_Scn = TestDef_Scn.new("<none>", nil)
  FactInst_Mix = TestDef_Mix.new("<none>", nil)
  FactInst_Inf = TestDef_Inf.new("<none>", nil)

  # A table that holds the various definition factories
  Def_table = [ FactInst_App,
                FactInst_Dev,
                FactInst_Usr,
                FactInst_Scn,
                FactInst_Mix,
                FactInst_Inf ]

  # Table of "persistence prefix" values for all the definition flavors
  Def_prefs = Def_table.collect { |i| i.persist_pref }

  # Table that maprsx from "persistence prefix" to a definition class instance
  Def_mapps = {}
  Def_table.each { |i| Def_mapps[i.persist_pref.to_s] = i }


end

require File.expand_path('../vmc_base', __FILE__)

module STAC
  # Takes an ActionQueue and splits it into seperate queues per context
  # (which need to be serialized) and keeps them ordered in a priority
  # queue based on the synthetic clock time that they are supposed
  # to run at.  The action queue that is passed in is already sorted
  # by the :clock time.
  class PriorityQueueManager
    
    @@single_instance = nil 
    
    def initialize(action_queues)
      @lock   = Mutex.new
      @priority_queue = Containers::PriorityQueue.new

      @lock.synchronize {
        context_queues = {}
        
        # Here will generate multi queue according to different context
        action_queues.each do |action_queue|
          context_queue = context_queues[action_queue[:context][:global_scn_index]] ||= []
          context_queue << action_queue
        end

        context_queues.values.each do |context_queue|
          @@logger.debug("PriorityQueue pushing context #{context_queue[0][:context][0]}")
          @priority_queue.push(context_queue, -context_queue[0][:clock])
        end
        @@logger.info("PriorityQueue created #{context_queues.length} context queues")
      }
    end
    
    def self.factory(action_queue = nil)
      @@single_instance = new(action_queue) unless @@single_instance
      @@single_instance
    end
    
    def self.prioritize(action_queues)
      PriorityQueueManager.factory(action_queues)
    end

    def self.set_logger(logger)
      @@logger = logger
    end

    # returns a context_queue.  the caller has to push it back in
    # when they are done with it
    def pop
      context_queue = @lock.synchronize { @priority_queue.pop }
      @@logger.debug("PriorityQueue thread #{Thread.current.object_id} popped context #{context_queue[0][:context].to_s}") if context_queue
      context_queue
    end
    
    def self.pop
      self.factory.pop
    end

    # pushes a context_queue back into the priority queue
    def push(context_queue)
      # use a negative clock value as bigger numbers have higher priority
      @@logger.debug("PriorityQueue thread #{Thread.current.object_id} pushing context #{context_queue[0][:context].to_s}")
      @lock.synchronize { @priority_queue.push(context_queue, -context_queue[0][:clock]) }
    end
    
    def self.push(context_queue)
      self.factory.push(context_queue)
    end

    def length
      @lock.synchronize { @priority_queue.length }
    end
  end
  
  class ActionQueueManager
    @@queue_lock = Mutex.new
    @@queue  = []
    @@jitter     = 0
    @@logger     = nil
    @@max_clock  = 0

    def self.set_logger(logger)
      @@logger = logger
    end
    
    def self.add_item(item)
      @@queue_lock.synchronize do
        @@queue << item
      end
    end
    
    def self.get_queue
      return @@queue
    end
    
    def self.print()
      @@queue.each do |queue_item|
        puts queue_item
      end
    end

    def self.enqueue(inst, clock, state, action, args, displayStr)
      @@queue_lock.synchronize do
        @@logger.debug("        [#{STAC::act_prefix(clock, state)}] >>" + displayStr)
        @@queue <<
        {
          :context  => [ state[:ac_user_num] , state[:ac_scen_num] ],
          :uniquex  => state[:uniquex],
          :act_type => inst,
          :clock    => clock,
          :action   => action,
          :args     => args,
          :seq      => @@queue.length
        }
        @@max_clock = clock if @@max_clock < clock
      end
    end

    def self.enqueue_dev(inst, clock, state, action, appname, args = nil)
      displayStr = "vmc #{VMC_Actions.action_to_s(action)} #{appname} #{args.inspect}"
      args = args ? args.dup : {}
      args[:app_name] = appname
      enqueue(inst, clock, state, action, args, displayStr)
    end

    def self.enqueue_use(inst, clock, state, action, args)
      if not action.kind_of? Symbol
        puts "FATAL: use actions must always have :action" ; exit
      end
      displayStr = "use #{args.inspect}"
      enqueue(inst, clock, state, action, args, displayStr)
    end

    def self.merge_queues
      @@queue.sort do |a, b|
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
    
    # Assemble action and put it to the queue
    def self.assemble_action_queue(mix_id)
      instance = MixManager.query_instance(mix_id)
      
      # Count User Number
      dev_user_num = 0
      global_scn_index = 0
      if instance
        instance.test_mix.each_with_index do |test_mix_item, test_mix_item_index|
          
          # Assign some variable to value
          test_mix_item.expand()
          
          # Get predefined variable with value for scenario
          scn_var = test_mix_item.scn_var
          
          test_mix_item.count.times do |count_in_scn|
            test_mix_item.scn_mix.each do |scn_mix_item|
              add_dev_user_action = false # Add Dev User flag, no Dev Action, no
              clock = 0 
              scn_mix_item.scn_ref.scn_actions.each do |scn_action_item|
                act_ref = scn_action_item.act_ref
                act_arg = scn_action_item.act_arg
                
                # Context format like {scn_id, scn_index, count_in_scn}
                context = {:scn_id =>scn_mix_item.scn_ref.id, :global_scn_index => global_scn_index, :scn_index => test_mix_item_index, :count_num => count_in_scn}
                if !add_dev_user_action and scn_action_item.act_ref and scn_action_item.act_ref.kind_of? Dev_Actions
                  add_user_action = Scn_Action.new # New a action of Add User
                  
                  add_user_action.act_ref = DevManager.query_instance(:stac_dev_add_user) # Connect with ref
                  user_name = "ac_test_user_%04u" % dev_user_num + "@vmware.com"
                  context[:user_name] = user_name
                  add_user_action.act_arg = {:user_name => user_name, :password => "goodluck"}
                  
                  action_item = wrap_queue_item(context, add_user_action, clock, 1)
                  
                  # Add the action for adding Dev User
                  add_item(action_item)
                  dev_user_num += 1
                  clock += 1
                  add_dev_user_action = true
                end
                
                # Convert expression to concrete value, e.g, :duration => "$usr_duration|60"
                # This part should be doing at run-time not a proactivity because there may exist posibility that many Scenario Depended
                # on same action, changing the variable of action is not correct way
                #act_arg.each do |key, value|
                  #act_arg[key] = evaluate_value(scn_var, value)
                #end

                duration = evaluate_value(scn_var, act_arg[:duration])
                if duration.kind_of? String
                  if duration.downcase=="infinity"
                    duration = infinity
                  else
                    duration = duration.to_i
                  end
                end
                
                duration = 1 if duration<=0
                
                action_item = wrap_queue_item(context, scn_action_item, clock, duration, scn_var)
                add_item(action_item)
                
                clock += duration
              end
            end
            global_scn_index += 1
          end
        end
      end
    end
    
    def self.wrap_queue_item(context, action, clock, duration, scn_var=nil)
      {
        :context  => context,
        :action   => action,
        :clock    => clock,
        :duration => duration,
        :scn_var => scn_var
      }
    end
    
    def self.evaluate_value(scn_var, expression)
      if expression.to_s.match(/^\$.+\|.+$/)
        # The mark "|" here is to seperate the variable and default value, if no value passed, the default value will be used 
        matchTmp = expression.to_s.match(/^\$(.+)\|(.+)$/)
        keyInData = matchTmp[1]
        defaultValue = matchTmp[2]
        if scn_var[keyInData.to_sym]
          scn_var[keyInData.to_sym]
        else
          matchTmp[2]
        end
      elsif expression.to_s.match(/^\$.+$/)
        matchTmp = value.to_s.match(/^\$(.+)$/)
        keyInData = matchTmp[1]
        if scn_var[keyInData]
          scn_var[keyInData]
        else
          # If no value passed and default value existed, popup error and quit
          @@logger.error("The variable #{keyInData} is not defined in test mix level")
          exit 1
        end
      else 
        expression
      end
    end
  end
end

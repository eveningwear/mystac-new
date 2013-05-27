require File.expand_path('../util/vmc_base', __FILE__)
require File.expand_path('../util/http_loader', __FILE__)

module STAC
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
  
  class ActionQueue
    @@queue_lock = Mutex.new
    @@queue  = []
    @@jitter     = 0
    @@logger     = nil
    @@max_clock  = 0

    def self.set_logger(logger)
      @@logger = logger
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
  end
end

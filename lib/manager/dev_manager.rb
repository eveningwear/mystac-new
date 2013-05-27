
module STAC
  
  class DevManager < BaseManager
    
    @@single_instance = nil 
    
    def initialize(logger)
      super(Dev_Actions, logger)
    end
    
    def parse_data(data, file)
      super
    end
    
    def self.factory(logger = nil)
      @@single_instance = new(logger) unless @@single_instance
      @@single_instance
    end
    
    def self.generate_action_info(act_ref, act_arg, scn_var)
      info = {}
      info.action = act_ref
      return 
    end
  end
end
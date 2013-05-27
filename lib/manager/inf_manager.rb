
module STAC
  
  class InfManager < BaseManager
    
    @@single_instance = nil
    
    def initialize(logger)
      super(nil, logger)
    end
    
    def self.factory(logger = nil)
      unless @@single_instance
        @@single_instance = new(logger)
        
        #Add 4 predefine functions as instance for serving other model such as Scnario
        @@single_instance.predefine()
      end
      
      @@single_instance
    end
    
    def predefine()
      @instances[:stac_inf_set_state]  = Information.new.fill({:exec => :exec_set_var})
      @instances[:stac_inf_def_state]  = Information.new.fill({:exec => :exec_def_var})
      @instances[:stac_inf_repeat_beg] = Information.new.fill({:exec => :exec_rep_beg})
      @instances[:stac_inf_repeat_end] = Information.new.fill({:exec => :exec_rep_end})
    end
  end
end
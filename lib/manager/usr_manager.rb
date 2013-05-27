
module STAC
  
  class UsrManager < BaseManager
    
    @@single_instance = nil 
    
    def initialize(logger)
      super(Usr_Actions, logger)
    end
    
    def parse_data(data, file)
      super
    end
    
    def self.factory(logger = nil)
      @@single_instance = new(logger) unless @@single_instance
      @@single_instance
    end
  end
end
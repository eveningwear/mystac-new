
module STAC
  
  class BaseManager
    
    attr_accessor :instances
    
    # Blank function for overriden by sub class
    def self.factory(logger)
      @logger.error("This function should be never called here")
    end
    
    def initialize(target_class, logger)
      @instances = {}
      @target_class = target_class
      @logger = logger
    end
    
    # Parse the file content writen in DSL
    def parse_data(data, file)
      @logger.debug("Parse #{@target}")
      instance = @target_class.new
      instance.src = file
      instance.fill(data)
      @instances[instance.id] = instance
    end
    
    # Staic function for query instance
    def self.query_instance(id)
      self.factory(nil).query_instance(id)
    end
    
    # Query instance by id
    def query_instance(id)
      return @instances[id] if @instances[id]
      return @instances[id.to_s] if @instances[id.to_s]
      return @instances[id.to_sym] if @instances[id.to_sym]
    end
    
    # Get manager by parsing id
    def self.get_manager(id)
      prefix = parse_prefix(id)
      manager = eval("#{prefix.capitalize}Manager.factory(nil)")
      manager
    end
    
    # This is to get the prefix from id, e.g, get "mix" from "stac_mix_simple_sinatra"
    def self.parse_prefix(id)
      parts = id.to_s.match(/^stac_([a-z]+[a-z0-9]*)_[a-z0-9_]+/)
      parts[1]
    end
  end
end

module STAC
  class Information < Identity
    
    attr_accessor :exec

    def fill(data)
      super
      @exec = method(@exec)
      self
    end
    
    def exec_rep_beg(args)
    end

    def exec_rep_end(args)
    end

    def exec_set_var(args)
    end

    def exec_def_var(args)
      var = args[:var].to_s
      val = args[:val].to_s
      
      return [var, val]
    end
  end
end
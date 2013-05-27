require 'restclient'

module HttpLoad
  @@default_url = nil

  def http_load(args)
    if args.key? :url
      url = args[:url]
    elsif 
      args.key? :urlfile
      urlfile = args[:urlfile]
    elseif
      syntax_error "missing url or url file."
    end
  end

  def self.gen_traffic(url,rate,duration)
    start = Time.now.to_i
    delta = 1.0/rate.to_f
    begin
      puts "getting " + url
      RestClient.get url
      #sleep delta
    end until Time.now.to_i - start >= duration
  end
end

    
  

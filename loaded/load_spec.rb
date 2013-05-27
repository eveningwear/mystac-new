REQUEST_TIMEOUT = 2
EXECUTE = ENV['LOADED_EXECUTE']

def vmc(command, *params)
  user = ENV['LOADED_USERNAME']
  proxy_user = user ? "-u #{user}" : ""
  str = "vmc #{proxy_user} #{command} #{(params.map{|x| ' ' + x.to_s + ' '}).join}"
  puts str
  system(str) if EXECUTE
end

def ab_load(url, *params)
  str = 'ab ' '-t ' + REQUEST_TIMEOUT.to_s +  ' ' + (params.map{|x| ' ' + x.to_s + ' '}).join + url
  puts str
  system(str) if EXECUTE
end



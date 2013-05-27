#!/usr/bin/ruby -w
require 'optparse'

$execute = true
$user_file = nil
$create_users = false
NAME_TEMPLATE = "ac_test_user_%04u@vmware.com" 
USAGE = $0 + " [OPT] [num_users], operate on 0..num_users by default, use -h for help"

def parse_options
  options = OptionParser.new do |opts|
    opts.banner = USAGE
    opts.on("-f", "--file FILE", "search file for users to kill") do |opt|
      $user_file = opt
    end
    opts.on("-c", "--create", "create users instead of deleteing them") do |opt|
      $create_users = opt
    end
    opts.on("-t", "--trace", "don't execute just trace") do
      $execute = false
    end
    opts.on("-h", "--help", "Help") do
      puts opts
      exit
    end
  end
  options.parse!(ARGV)
end

def do_system(command)
  puts command
  system(command) if $execute
end

def register_user(email)
  puts "setting up user #{email}"
  do_system("vmc register --email #{email} --passwd test")
end

def unregister_user(email)
  puts "removing user #{email}"
  do_system("vmc unregister #{email}")
end

def user_names(num_users)
  names = []
  (0..num_users).each{|unum| names << NAME_TEMPLATE % unum}
  names
end

def match_users(file)
  f = open(file)
  text = f.read
  users = text.grep(/(ac_test_user_.*vmware.com)/).map {|x| x.rstrip}
  puts "found users..."
  puts users
  users
end

def setup_users(users)
  users.each {|name| register_user(name)}
end

def delete_users(users)
  users.each {|name| unregister_user(name)}
end

def p_setup_users(users)
  users.each {|name| 
    pid = fork do
      register_user(name)
    end
  }
  Process.waitall
end

def p_delete_users(users)
  users.each { |name| 
    pid = fork do
      unregister_user(name)
    end
  }
  Process.waitall
end

def time
  start_time = Time.now
  yield
  end_time = Time.now
  end_time - start_time
end

if __FILE__ == $0
  parse_options
  if $user_file
    users = match_users($user_file)
  else
    num_users = ARGV[0].to_i
    users = user_names(num_users)
  end
  if $create_users
    puts "setup took #{time{p_setup_users(users)}}"
  else
    puts "cleanup took #{time{p_delete_users(users)}}"
  end
end

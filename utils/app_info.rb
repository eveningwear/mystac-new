require 'rubygems'
require 'fileutils'
require 'zip/zipfilesystem'

mem          = nil
exec         = nil
svcs         = nil
framework    = nil
opt_war_file = nil

if File.exist?('config/environment.rb')
  framework = "rails/1.0"
elsif Dir.glob('*.war').first
  opt_war_file = Dir.glob('*.war').first
  entries = []
  Zip::ZipFile.foreach(opt_war_file) { |zentry| entries << zentry }
  contents = entries.join("\n")

  if contents =~ /WEB-INF\/grails-app/
    framework = "grails/1.0"
    mem = '512M'
  elsif contents =~ /WEB-INF\/classes\/org\/springframework/
    framework = "spring_web/1.0"
    mem = '512M'
  elsif contents =~ /WEB-INF\/lib\/spring-core.*\.jar/
    framework = "spring_web/1.0"
    mem = '512M'
  else
    framework = "spring_web/1.0"
  end
elsif File.exist?('web.config')
  framework = "asp_web/1.0"
elsif !Dir.glob('*.rb').empty?
  matched_file = nil
  Dir.glob('*.rb').each do |fname|
    next if matched_file
    File.open(fname, 'r') do |f|
      str = f.read # This might want to be limited
      matched_file = fname if (str && str.match(/^\s*require\s*'sinatra'/i))
    end
  end
  if matched_file && !File.exist?('config.ru')
    exec = "ruby #{matched_file}"
  end
  mem = '128M'
elsif !Dir.glob('*.js').empty?
  if File.exist?('app.js')
    framework = "nodejs/1.0"
    mem = '64M'
  end
end

exit 1 unless framework

# Based on the current directory figure out the app name
appdir = FileUtils.pwd

# Strip off the path to B29 if it's present
test = appdir.index("/core/tests/apps/")
if test
  pref = 17
else
  test = appdir.index("/apps/")
  pref = 6
end
if test
  appname = appdir[test + pref .. -1]
  appdir[0 .. test] = "../"
  appname[-4 .. -1] = "" if appname[-4 .. -1] == "_app"
  appname.gsub('/','_')
else
  puts "WARNING: cannot figure out app name from current dir #{appdir}; using 'foo'"
  appname = "foo"
end

info =  "{\n" +
        "    :id => :stac_app_#{appname},\n" +
        "    :description => \"...\",\n" +
        "\n" +
        "    :app_dir  => \"#{appdir}\",\n" +
        "    :app_fmwk => \"#{framework}\",\n"

info += "    :app_exec => \"#{exec}\",\n" if exec
info += "    :app_svcs => #{svcs},\n" if svcs
info += "    :app_mem  => \"#{mem}\",\n" if mem
info += "    :app_war  => \"#{opt_war_file}\",\n" if opt_war_file

info += "}\n"

# Figure out whether we need to write out a stac file or just spew to stdout
if ARGV.length == 1
  File.open(ARGV[0] + "/#{appname}.stac", 'w') { |f| f.write(info) }
else
  puts info
end

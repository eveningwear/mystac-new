require 'load_spec'
require 'fileutils'

appname = ENV['LOADED_APPNAME'] or  'barf'
appurl = "#{appname}.b29.me"
appdir = File.join FileUtils.getwd, 'bar'
aburl = "http://#{appurl}/"

FileUtils.cd appdir

vmc 'push', appname , '--path ' + appdir, '--url ' + appurl, '--mem 128M' 

ab_load aburl, '-n 30', '-c 5'

vmc 'instances', appname, 10

ab_load aburl, '-n 60', '-c 10'

vmc 'delete', appname

#!/usr/bin/env ruby

require 'rubygems'
require 'erb'
require 'thin'
require 'fileutils'
require 'nats/client'
require 'net/http'
require 'algorithms'
require 'pp'

ROOT = File.expand_path(File.dirname(__FILE__))

module STAC
	autoload :StressTestExec,  "#{ROOT}/executor"
	autoload :StressTestRunner,  "#{ROOT}/runner"
	#autoload :TestDef_Base,  "#{ROOT}/define/test_define"
	autoload :TestDef_Inf,  "#{ROOT}/define/test_define"
	autoload :TestDef_App,  "#{ROOT}/define/test_define"
	autoload :TestDef_Dev,  "#{ROOT}/define/test_define"
	autoload :TestDef_Usr,  "#{ROOT}/define/test_define"
	autoload :TestDef_Scn,  "#{ROOT}/define/test_define"
	autoload :TestDef_Mix,  "#{ROOT}/define/test_define"
	autoload :VMC_Actions,  "#{ROOT}/action/vmc_action"
	autoload :PriorityContextQueue,  "#{ROOT}/queue"
	autoload :ActionQueue,  "#{ROOT}/queue"
	
  autoload :SeedManager, "#{ROOT}/manager/seed_manager"
	
  autoload :BaseManager, "#{ROOT}/manager/base_manager"
  autoload :AppManager,  "#{ROOT}/manager/app_manager"
  autoload :DevManager,  "#{ROOT}/manager/dev_manager"
  autoload :InfManager,  "#{ROOT}/manager/inf_manager"
  autoload :ScnManager,  "#{ROOT}/manager/scn_manager"
  autoload :MixManager,  "#{ROOT}/manager/mix_manager"
  autoload :UsrManager,  "#{ROOT}/manager/usr_manager"
  
  autoload :Base_Model,   "#{ROOT}/model/base"
  autoload :Identity,     "#{ROOT}/model/base"
  autoload :Application,  "#{ROOT}/model/app"
  autoload :Dev_Actions,  "#{ROOT}/model/dev"
  autoload :Information,  "#{ROOT}/model/inf"
  autoload :Test_Mixes,   "#{ROOT}/model/mix"
  autoload :Scenario,     "#{ROOT}/model/scn"
  autoload :Usr_Actions,  "#{ROOT}/model/usr"
  
  autoload :ActionQueueManager,   "#{ROOT}/util/queue"
  autoload :PriorityQueueManager, "#{ROOT}/util/queue"
end


# Copyright 2010, VMware, Inc. Licensed under the
# MIT license, please see the LICENSE file.  All rights reserved

require 'digest/sha1'
require 'fileutils'
require 'tempfile'
require 'tmpdir'

# self contained
$:.unshift File.expand_path('../../vendor/gems/httpclient/lib', __FILE__)

require 'httpclient'
require 'zip/zipfilesystem'
require 'json/pure'

# This class captures the common interactions with AppCloud that can be shared by different
# clients. Clients that use this class are the vmc CLI and the integration test automation.
# TBD - ABS: This is currently a minimal extraction of methods to tease out
# the interactive aspects of the vmc CLI from the AppCloud API calls.


class Fixnum
  def to_json(options = nil)
    to_s
  end
end

class Bignum
  def to_json(options = nil)
    to_s
  end
end

module VMC
  class BaseClient
    attr_accessor :trace

    def wrap(method,uri, query = nil,extheader ={})
       if @trace
         puts '>>>'
         puts method.upcase + "  " + uri
         puts 'QUERY:' + query.to_s if query
         response = HTTPClient.send(method, uri, query, extheader)
         print "REPLY(", response.status,'):', response.content + "\n" if @trace
         puts '<<<'
       else
         response = HTTPClient.send(method, uri, query, extheader)
       end
       response
    end

    def get(uri, query = nil,extheader ={})
      wrap(__method__.to_s,uri,query,extheader)
    end

    def put(uri, query = nil,extheader ={})
      wrap(__method__.to_s,uri,query,extheader)
    end

    def post(uri, query = nil,extheader ={})
      wrap(__method__.to_s,uri,query,extheader)
    end

    def vmc_delete(uri, header)
      if @trace
        puts '>>>'
        puts 'DELETE' + "  " + uri
        response = HTTPClient.delete uri, header
        print "REPLY(", response.status,'):', response.content + "\n" if @trace
        puts '<<<'
      else
        response = HTTPClient.delete uri, header
      end
      response
    end

    def register_internal(base_uri, email, password, auth_hdr = {})
      response = post("#{base_uri}/users", {:email => email, :password => password}.to_json, auth_hdr)
      raise(JSON.parse(response.content)['description'] || 'registration failed') if response.status != 200 && response.status != 204
    end

    def login_internal(base_uri, email, password)
      response = post "#{base_uri}/users/#{email}/tokens", {:password => password}.to_json
      raise "login failed" if response.status != 200
      JSON.parse(response.content)['token']
    end

    def change_passwd_internal(base_uri, user_info, auth_hdr)
      email = user_info['email']
      response = put("#{base_uri}/users/#{email}", user_info.to_json, auth_hdr)
      raise(JSON.parse(response.content)['description'] || 'password change failed') if response.status != 200 && response.status != 204
    end

    def get_user_internal(base_uri, email, auth_hdr)
      response = get "#{base_uri}/users/#{email}", nil, auth_hdr
    end

    def delete_user_internal(base_uri, email, auth_hdr)
      response = vmc_delete "#{base_uri}/users/#{email}", auth_hdr
    end

    def get_apps_internal(droplets_uri, auth_hdr)
      response = get droplets_uri, nil, auth_hdr
      raise "(#{response.status}) can not contact server" if (response.status > 500 || response.status == 404)
      raise "Access Denied, please login or register" if response.status == 403
      droplets_full = JSON.parse(response.content)
    rescue => e
      error "Problem executing list command, #{e}"
    end

    def create_app_internal(droplets_uri, app_manifest, auth_hdr)
      test = app_manifest.to_json
      puts test
      response = post droplets_uri, test, auth_hdr
    end

    def get_app_internal(droplets_uri, appname, auth_hdr)
      response = get "#{droplets_uri}/#{appname}", nil, auth_hdr
    end

    def delete_app_internal(droplets_uri, services_uri, appname, services_to_delete, auth_hdr)
      vmc_delete "#{droplets_uri}/#{appname}", auth_hdr
      services_to_delete.each { |service_name|
        vmc_delete "#{services_uri}/#{service_name}", auth_hdr
      }
    end

    def upload_app_bits(path, resources_uri, droplets_uri, appname, auth_hdr, opt_war_file, provisioned_db = false)
      explode_dir = "#{Dir.tmpdir}/.vmc_#{appname}_files"
      FileUtils.rm_rf(explode_dir) # Make sure we didn't have anything left over..

      # Stage the app appropriately and do the appropriate fingerprinting, etc.
      if opt_war_file
        Zip::ZipFile.foreach(opt_war_file) { |zentry|
          epath = "#{explode_dir}/#{zentry}"
          FileUtils.mkdir_p(File.dirname(epath)) unless (File.exists?(File.dirname(epath)))
          zentry.extract("#{explode_dir}/#{zentry}")
        }
      else
        FileUtils.cp_r(path, explode_dir)
      end

      # Send the resource list to the cloud controller, the response will tell us what it already has..
      fingerprints = []
      resource_files = Dir.glob("#{explode_dir}/**/*", File::FNM_DOTMATCH)
      resource_files.each { |filename|
        fingerprints << { :size => File.size(filename),
                          :sha1 => Digest::SHA1.file(filename).hexdigest,
                          :fn => filename # TODO(dlc) probably should not send over the wire
        } unless (File.directory?(filename) || !File.exists?(filename))
      }

      # Send resource fingerprints to the cloud controller
      response = post resources_uri, fingerprints.to_json, auth_hdr
      appcloud_resources = nil
      if response.status == 200
        appcloud_resources = JSON.parse(response.content)
        # we will use the exploded version of the files here to whip through and delete what we
        # will have appcloud fill in for us.
        appcloud_resources.each { |resource| FileUtils.rm_f resource['fn'] }
      end

      # Perform Packing of the upload bits here.
      upload_file = "#{Dir.tmpdir}/#{appname}.zip"
      FileUtils.rm_f(upload_file)
      exclude = ['..', '*~', '#*#', '*.log']
      exclude << '*.sqlite3' if provisioned_db
      Zip::ZipFile::open(upload_file, true) { |zf|
        Dir.glob("#{explode_dir}/**/*", File::FNM_DOTMATCH).each { |f|
          process = true
          exclude.each { |e| process = false if File.fnmatch(e, File.basename(f)) }
          zf.add(f.sub("#{explode_dir}/",''), f) if (process && File.exists?(f))
        }
      }

      upload_size = File.size(upload_file);

      upload_data = {:application => File.new(upload_file, 'rb'), :_method => 'put'}
      if appcloud_resources
        # Need to adjust filenames sans the explode_dir prefix
        appcloud_resources.each { |ar| ar['fn'].sub!("#{explode_dir}/", '') }
        upload_data[:resources] = appcloud_resources.to_json
      end

      response = post "#{droplets_uri}/#{appname}/application", upload_data, auth_hdr
      raise "Problem uploading application bits (status=#{response.status})" if response.status != 200
      upload_size

    ensure
      # Cleanup if we created an exploded directory.
      FileUtils.rm_f(upload_file) if upload_file
      FileUtils.rm_rf(explode_dir)
    end

    def update_app_state_internal droplets_uri, appname, appinfo, auth_hdr
       hdrs = auth_hdr.merge({'content-type' => 'application/json'})
       response = put "#{droplets_uri}/#{appname}", appinfo.to_json, hdrs
    end

    def get_app_instances_internal(droplets_uri, appname, auth_hdr)
      response = get "#{droplets_uri}/#{appname}/instances", nil, auth_hdr
      return nil if response.status >= 400 or response.content == ""
      instances_info = JSON.parse(response.content)
    end

    def get_app_files_internal(droplets_uri, appname, instance, path, auth_hdr)
      cc_url = "#{droplets_uri}/#{appname}/instances/#{instance}/files/#{path}"
      cc_url.gsub!('files//', 'files/')
      response = get cc_url, nil, auth_hdr
    end

    def get_app_crashes_internal(droplets_uri, appname, auth_hdr)
      response = get "#{droplets_uri}/#{appname}/crashes", nil, auth_hdr
    end

    def get_app_stats_internal(droplets_uri, appname, auth_hdr)
      response = get "#{droplets_uri}/#{appname}/stats", nil, auth_hdr
    end

    def update_app_internal(droplets_uri, appname, auth_hdr)
      response = put "#{droplets_uri}/#{appname}/update", '', auth_hdr
    end

    def get_update_app_status(droplets_uri, appname, auth_hdr)
      response = get "#{droplets_uri}/#{appname}/update", nil, auth_hdr
      raise "Problem updating application" if response.status != 200
      response
    end

    def add_service_internal(services_uri, service_manifest, auth_hdr)
      response = post services_uri, service_manifest.to_json, auth_hdr
    end

    def remove_service_internal(services_uri, service_id, auth_hdr)
      vmc_delete "#{services_uri}/#{service_id}", auth_hdr
    end

    def delete_services_internal(services_uri, services, auth_hdr)
      services.each do |service_name|
        vmc_delete "#{services_uri}/#{service_name}", auth_hdr
      end
    end

    def fast_uuid
      values = [
        rand(0x0010000),rand(0x0010000),rand(0x0010000),
        rand(0x0010000),rand(0x0010000),rand(0x1000000),
        rand(0x1000000),
      ]
      "%04x%04x%04x%04x%04x%06x%06x" % values
    end

    def error(msg)
      STDERR.puts(msg)
    end
  end

end

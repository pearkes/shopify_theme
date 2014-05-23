require 'thor'
require 'yaml'
YAML::ENGINE.yamler = 'syck' if defined? Syck
require 'abbrev'
require 'base64'
require 'fileutils'
require 'json'
require 'listen'
require 'launchy'
require 'less'
require 'uglifier'

module ShopifyTheme
  class Cli < Thor
    include Thor::Actions

    BINARY_EXTENSIONS = %w(png gif jpg jpeg eot svg ttf woff otf swf ico mp4 ogg webm)
    IGNORE = %w(config.yml)
    DEFAULT_WHITELIST = %w(layout/ assets/ config/ snippets/ templates/)
    TIMEFORMAT = "%H:%M:%S"

    tasks.keys.abbrev.each do |shortcut, command|
      map shortcut => command.to_sym
    end

    desc "check", "check configuration"
    def check
      if ShopifyTheme.check_config
        say("Configuration [OK]", :green)
      else
        say("Configuration [FAIL]", :red)
      end
    end

    desc "download FILE", "download the shops current theme assets"
    method_option :quiet, :type => :boolean, :default => false
    def download(*keys)
      assets = keys.empty? ? ShopifyTheme.asset_list : keys

      assets.each do |asset|
        download_asset(asset)
        say("Downloaded: #{asset}", :green) unless options['quiet']
      end
      say("Done.", :green) unless options['quiet']
    end

    desc "upload FILE", "upload all theme assets to shop"
    method_option :quiet, :type => :boolean, :default => false
    def upload(*keys)
      assets = keys.empty? ? local_assets_list : keys
      assets.each do |asset|
        send_asset(asset, options['quiet'])
      end
      say("Done.", :green) unless options['quiet']
    end

    desc "replace FILE", "completely replace shop theme assets with local theme assets"
    method_option :quiet, :type => :boolean, :default => false
    def replace(*keys)
      # only delete files on remote that are not present locally
      # files present on remote and present locally get overridden anyway
      remote_assets = keys.empty? ? (ShopifyTheme.asset_list - local_assets_list) : keys
      remote_assets.each do |asset|
        delete_asset(asset, options['quiet'])
      end
      local_assets = keys.empty? ? local_assets_list : keys
      local_assets.each do |asset|
        send_asset(asset, options['quiet'])
      end
      say("Done.", :green) unless options['quiet']
    end

    desc "remove FILE", "remove theme asset"
    method_option :quiet, :type => :boolean, :default => false
    def remove(*keys)
      keys.each do |key|
        delete_asset(key, options['quiet'])
      end
      say("Done.", :green) unless options['quiet']
    end

    desc "watch", "upload and delete individual theme assets as they change, use the --keep_files flag to disable remote file deletion"
    method_option :quiet, :type => :boolean, :default => false
    method_option :keep_files, :type => :boolean, :default => false
    def watch
      ShopifyTheme.check_config
      say("Connected to home tree", :green)
      say("Watching site...")

      Listen.to!(Dir.pwd, :relative_paths => true) do |modified, added, removed|
        modified.each do |filePath|
          next if filePath == "assets/application.min.js"
          next if filePath == "assets/application.min.css.liquid"
          next if filePath == "assets/checkout.css.liquid"

          say("Change detected! Syncing...")

          # Special-case the JS
          if filePath.include?('js/')
            # Clear out the application.min file
            File.open("assets/application.min.js", "w") {|file| file.truncate(0) }

            Dir.entries("js/").each do |js_file|
              next if !js_file.include?(".js")
              File.open("assets/application.min.js", "a") do |f|
                f << Uglifier.compile(File.read("js/#{js_file}"))
              end
            end

            send_asset("assets/application.min.js", options['quiet'])
          end

          # Special-case the less
          if filePath.include?('less/')
            success = false
            parser = Less::Parser.new

            File.open("assets/application.min.css.liquid", "w") do |f|
              compile = parser.parse(File.read("less/base.less"))
              f << compile.to_css(:compress => true)
              success = true
            end

            send_asset("assets/application.min.css.liquid", options['quiet']) if success

            success = false
            parser = Less::Parser.new

            File.open("assets/checkout.css.liquid", "w") do |f|
              compile = parser.parse(File.read("less/checkout.less"))
              f << compile.to_css(:compress => true)
              success = true
            end

            send_asset("assets/checkout.css.liquid", options['quiet']) if success
          end

          if local_assets_list.include?(filePath)
            send_asset(filePath, options['quiet'])
          end
        end

        added.each do |filePath|
          say("Change detected! Syncing...")
          send_asset(filePath, options['quiet']) if local_assets_list.include?(filePath)
        end

        if !options['keep_files']
          removed.each do |filePath|
            say("Change detected! Syncing...")
            delete_asset(filePath, options['quiet']) if local_assets_list.include?(filePath)
          end
        end
      end

    rescue Interrupt
      puts "exiting..."
    end

    private

    def local_assets_list
      local_files.reject do |p|
        @permitted_files ||= (DEFAULT_WHITELIST | ShopifyTheme.whitelist_files).map{|pattern| Regexp.new(pattern)}
        @permitted_files.none? { |regex| regex =~ p }
      end
    end

    def local_files
      Dir.glob(File.join('**', '*'))
    end

    def download_asset(key)
      asset = ShopifyTheme.get_asset(key)
      if asset['value']
        # For CRLF line endings
        content = asset['value'].gsub("\r", "")
        format = "w"
      elsif asset['attachment']
        content = Base64.decode64(asset['attachment'])
        format = "w+b"
      end

      FileUtils.mkdir_p(File.dirname(key))
      File.open(key, format) {|f| f.write content} if content
    end

    def send_asset(asset, quiet=false)
      time = Time.now
      data = {:key => asset}
      content = File.read(asset)
      if BINARY_EXTENSIONS.include?(File.extname(asset).gsub('.','')) || ShopifyTheme.is_binary_data?(content)
        content = IO.read asset
        data.merge!(:attachment => Base64.encode64(content))
      else
        data.merge!(:value => content)
      end

      if (response = ShopifyTheme.send_asset(data)).success?
        say("[" + time.strftime(TIMEFORMAT) + "] Uploaded: #{asset}", :green) unless quiet
      else
        say("[" + time.strftime(TIMEFORMAT) + "] Error: Could not upload #{asset}. #{errors_from_response(response)}", :red)
      end
    end

    def delete_asset(key, quiet=false)
      time = Time.now
      if (response = ShopifyTheme.delete_asset(key)).success?
        say("[" + time.strftime(TIMEFORMAT) + "] Removed: #{key}", :green) unless quiet
      else
        say("[" + time.strftime(TIMEFORMAT) + "] Error: Could not remove #{key}. #{errors_from_response(response)}", :red)
      end
    end

    def errors_from_response(response)
      return unless response.parsed_response

      errors = response.parsed_response["errors"]

      case errors
      when NilClass
        ''
      when String
        errors
      else
        errors.values.join(", ")
      end
    end
  end
end

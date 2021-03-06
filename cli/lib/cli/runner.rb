# Copyright (c) 2009-2012 VMware, Inc.

module Bosh::Cli
  class ParseTreeNode < Hash
    attr_accessor :command
  end

  class Runner
    COMMANDS = { }
    ALL_KEYWORDS = []

    attr_reader :usage
    attr_reader :namespace
    attr_reader :action
    attr_reader :args
    attr_reader :options

    # The runner is an instance of the command type that the user issued,
    # such as a Deployment instance.  This is an accessor for testing.
    # @return [Bosh::Cli::Command::<type>] Instance of the command instance.
    attr_accessor :runner

    def self.run(args)
      new(args).run
    end

    def initialize(args)
      trap("SIGINT") {
        handle_ctrl_c
      }
      define_commands
      @args = args
      @options = {
          :director_checks => true,
          :colorize => true,
      }
    end

    ##
    # When user issues ctrl-c it asks if they really want to quit. If so
    # then it will cancel the current running task if it exists.
    def handle_ctrl_c
      if !@runner.task_running?
        exit(1)
      elsif kill_current_task?
        @runner.cancel_current_task
        exit(1)
      end
    end

    ##
    # Asks user if they really want to quit and returns the boolean answer.
    #
    # @return [Boolean] Whether the user wants to quit or not.
    def kill_current_task?
      # Use say and stdin.gets instead of ask because of 2 bugs in Highline.
      # The bug makes it so that if something else has called ask and was in
      # the middle of waiting for a response then ctrl-c is issued and it
      # calls ask again then highline will re-issue the first question again.
      # If the input is a newline character then highline will choke.
      say("\nAre you sure you'd like to cancel running tasks? [yN]")
      $stdin.gets.chomp.downcase == "y"
    end

    def prepare
      define_commands
      define_plugin_commands
      build_parse_tree
      add_shortcuts
      parse_options!

      Config.interactive = !@options[:non_interactive]
      Config.colorize    = @options.delete(:colorize)
      Config.output    ||= STDOUT unless @options[:quiet]
    end

    def run
      prepare
      dispatch unless @namespace && @action

      if @namespace && @action
        ns_class_name = @namespace.to_s.gsub(/(?:_|^)(.)/) { $1.upcase }
        klass = eval("Bosh::Cli::Command::#{ns_class_name}")
        @runner = klass.new(@options)
        @runner.usage = @usage

        action_arity = @runner.method(@action.to_sym).arity
        n_required_args = action_arity >= 0 ? action_arity : -action_arity - 1

        if n_required_args > @args.size
          err("Not enough arguments, correct usage is: bosh #{@usage}")
        end
        if action_arity >= 0 && n_required_args < @args.size
          err("Too many arguments, correct usage is: bosh #{@usage}")
        end

        @runner.send(@action.to_sym, *@args)
      elsif @args.empty? || @args == ["help"]
        say(help_message)
        say(plugin_help_message) if @plugins
      elsif @args[0] == "help"
        cmd_args = @args[1..-1]
        suggestions = command_suggestions(cmd_args).map do |cmd|
          command_usage(cmd, 0)
        end
        if suggestions.empty?
          unknown_command(cmd_args.join(" "))
        else
          say(suggestions.uniq.join("\n"))
        end
      else
        unknown_command(@args.join(" "))

        suggestions = command_suggestions(@args).map do |cmd|
          "bosh #{cmd.usage}"
        end

        if suggestions.size > 0
          say("Did you mean any of these?")
          say("\n" + suggestions.uniq.join("\n"))
        end
        exit(1)
      end

    rescue OptionParser::InvalidOption => e
      say(e.message.red + "\n" + basic_usage)
      exit(1)
    rescue Bosh::Cli::GracefulExit => e
      # Redirected bosh commands end up
      # generating this exception (kind of goto)
    rescue Bosh::Cli::CliExit, Bosh::Cli::DirectorError => e
      say(e.message.red)
      exit(e.exit_code)
    rescue Bosh::Cli::CliError => e
      say("Error #{e.error_code}: #{e.message}".red)
      exit(e.exit_code)
    rescue => e
      if @options[:debug]
        raise e
      else
        save_exception(e)
        exit(1)
      end
    end

    def command(name, &block)
      cmd_def = CommandDefinition.new
      cmd_def.instance_eval(&block)
      COMMANDS[name] = cmd_def
      ALL_KEYWORDS.push(*cmd_def.keywords)
    end

    def find_command(name)
      COMMANDS[name] || raise("Unknown command definition: #{name}")
    end

    def dispatch(command = nil)
      command ||= search_parse_tree(@parse_tree)
      command = try_alias if command.nil? && Config.interactive
      return if command.nil?
      @usage = command.usage

      case command.route
        when Array
          @namespace, @action = command.route
        when Proc
          @namespace, @action = command.route.call(@args)
        else
          raise "Command definition is invalid, " +
                    "route should be an Array or Proc"
      end
    end

    def define_commands
      command :version do
        usage "version"
        desc  "Show version"
        route :misc, :version
      end

      command :alias do
        usage "alias <name> <command>"
        desc  "Create an alias <name> for command <command>"
        route :misc, :set_alias
      end

      command :target do
        usage "target [<name>] [<alias>]"
        desc  "Choose director to talk to (optionally creating an alias). " +
                  "If no arguments given, show currently targeted director"
        route do |args|
          (args.size > 0) ? [:misc, :set_target] : [:misc, :show_target]
        end
      end

      command :deployment do
        usage "deployment [<name>]"
        desc  "Choose deployment to work with " +
                  "(it also updates current target)"
        route do |args|
          if args.size > 0
            [:deployment, :set_current]
          else
            [:deployment, :show_current]
          end
        end
      end

      command :deploy do
        usage  "deploy"
        desc   "Deploy according to the currently selected " +
                   "deployment manifest"
        option "--recreate", "recreate all VMs in deployment"
        route  :deployment, :perform
      end

      command :ssh do
        usage "ssh <job> [index] [<options>] [command]"
        desc  "Given a job, execute the given command or " +
              "start an interactive session"
        option "--public_key <file>"
        option "--gateway_host <host>"
        option "--gateway_user <user>"
        option "--default_password", "Use default ssh password. Not recommended."
        route :ssh, :shell
      end

      command :ssh_cleanup do
        usage "ssh_cleanup <job> [index]"
        desc  "Cleanup SSH artifacts"
        route :ssh, :cleanup
      end

      command :scp do
        usage "scp <job> [index] (--upload|--download) [options]" +
          "/path/to/source /path/to/destination"
        desc  "upload/download the source file to the given job. " +
          "Note: for dowload /path/to/destination is a directory"
        option "--public_key <file>"
        option "--gateway_host <host>"
        option "--gateway_user <user>"
        route :ssh, :scp
      end

      command :scp do
        usage "scp <job> <--upload | --download> [options] " +
                  "/path/to/source /path/to/destination"
        desc  "upload/download the source file to the given job. " +
                  "Note: for dowload /path/to/destination is a directory"
        option "--index <job_index>"
        option "--public_key <file>"
        option "--gateway_host <host>"
        option "--gateway_user <user>"
        route :ssh, :scp
      end

      command :status do
        usage "status"
        desc  "Show current status (current target, " +
                  "user, deployment info etc.)"
        route :misc, :status
      end

      command :login do
        usage "login [<name>] [<password>]"
        desc  "Provide credentials for the subsequent interactions " +
                  "with targeted director"
        route :misc, :login
      end

      command :logout do
        usage "logout"
        desc  "Forget saved credentials for targeted director"
        route :misc, :logout
      end

      command :purge do
        usage "purge"
        desc  "Purge local manifest cache"
        route :misc, :purge_cache
      end

      command :create_release do
        usage  "create release"
        desc   "Create release (assumes current directory " +
                   "to be a release repository)"
        route  :release, :create
        option "--force", "bypass git dirty state check"
        option "--final", "create production-ready release " +
            "(stores artefacts in blobstore, bumps final version)"
        option "--with-tarball", "create full release tarball" +
            "(by default only manifest is created)"
        option "--dry-run", "stop before writing release " +
            "manifest (for diagnostics)"
      end

      command :create_user do
        usage "create user [<name>] [<password>]"
        desc  "Create user"
        route :user, :create
      end

      command :create_package do
        usage "create package <name>|<path>"
        desc  "Build a single package"
        route :package, :create
      end

      command :start_job do
        usage  "start <job> [<index>]"
        desc   "Start job/instance"
        route  :job_management, :start_job

        power_option "--force"
      end

      command :stop_job do
        usage  "stop <job> [<index>]"
        desc   "Stop job/instance"
        route  :job_management, :stop_job
        option "--soft", "stop process only"
        option "--hard", "power off VM"

        power_option "--force"
      end

      command :restart_job do
        usage  "restart <job> [<index>]"
        desc   "Restart job/instance (soft stop + start)"
        route  :job_management, :restart_job

        power_option "--force"
      end

      command :recreate_job do
        usage "recreate <job> [<index>]"
        desc  "Recreate job/instance (hard stop + start)"
        route :job_management, :recreate_job

        power_option "--force"
      end

      command :fetch_logs do
        usage  "logs <job> <index>"
        desc   "Fetch job (default) or agent (if option provided) logs"
        route  :log_management, :fetch_logs
        option "--agent", "fetch agent logs"
        option "--only <filter1>[...]", "only fetch logs that satisfy " +
            "given filters (defined in job spec)"
        option "--all", "fetch all files in the job or agent log directory"
      end

      command :set_property do
        usage "set property <name> <value>"
        desc  "Set deployment property"
        route :property_management, :set
      end

      command :get_property do
        usage "get property <name>"
        desc  "Get deployment property"
        route :property_management, :get
      end

      command :unset_property do
        usage "unset property <name>"
        desc  "Unset deployment property"
        route :property_management, :unset
      end

      command :list_properties do
        usage  "properties"
        desc   "List current deployment properties"
        route  :property_management, :list
        option "--terse", "easy to parse output"
      end

      command :init_release do
        usage "init release [<path>]"
        desc  "Initialize release directory"
        route :release, :init
        option "--git", "initialize git repository"
      end

      command :generate_package do
        usage "generate package <name>"
        desc  "Generate package template"
        route :package, :generate
      end

      command :generate_job do
        usage "generate job <name>"
        desc  "Generate job template"
        route :job, :generate
      end

      command :upload_stemcell do
        usage "upload stemcell <path>"
        desc  "Upload the stemcell"
        route :stemcell, :upload
      end

      command :upload_release do
        usage "upload release [<path>]"
        desc  "Upload release (<path> can point to tarball or manifest, " +
                  "defaults to the most recently created release)"
        route :release, :upload
      end

      command :verify_stemcell do
        usage "verify stemcell <path>"
        desc  "Verify stemcell"
        route :stemcell, :verify
      end

      command :verify_release do
        usage "verify release <path>"
        desc  "Verify release"
        route :release, :verify
      end

      command :delete_deployment do
        usage "delete deployment <name>"
        desc  "Delete deployment"
        route :deployment, :delete
        option "--force", "ignore all errors while deleting parts " +
            "of the deployment"
      end

      command :delete_stemcell do
        usage "delete stemcell <name> <version>"
        desc  "Delete the stemcell"
        route :stemcell, :delete
      end

      command :delete_release do
        usage  "delete release <name> [<version>]"
        desc   "Delete release (or a particular release version)"
        route  :release, :delete
        option "--force", "ignore errors during deletion"
      end

      command :reset_release do
        usage "reset release"
        desc  "Reset release development environment " +
                  "(deletes all dev artifacts)"
        route :release, :reset
      end

      command :cancel_task do
        usage "cancel task <id>"
        desc  "Cancel task once it reaches the next cancel checkpoint"
        route :task, :cancel
      end

      command :track_task do
        usage  "task [<task_id>|last]"
        desc   "Show task status and start tracking its output"
        route  :task, :track
        option "--no-cache", "don't cache output locally"
        option "--event|--soap|--debug", "different log types to track"
        option "--raw", "don't beautify log"
      end

      command :list_stemcells do
        usage "stemcells"
        desc  "Show the list of available stemcells"
        route :stemcell, :list
      end

      command :list_public_stemcells do
        usage "public stemcells"
        desc  "Show the list of publicly available stemcells for download."
        route :stemcell, :list_public
      end

      command :download_public_stemcell do
        usage "download public stemcell <stemcell_name>"
        desc  "Downloads a stemcell from the public blobstore."
        route :stemcell, :download_public
      end

      command :list_releases do
        usage "releases"
        desc  "Show the list of available releases"
        route :release, :list
      end

      command :list_deployments do
        usage "deployments"
        desc  "Show the list of available deployments"
        route :deployment, :list
      end

      command :diff do
        usage "diff [<template_file>]"
        desc  "Diffs your current BOSH deployment configuration against " +
              "the specified BOSH deployment configuration template so that " +
              "you can keep your deployment configuration file up to date.  " +
              "A dev template can be found in deployments repos."
        route :biff, :biff
      end

      command :list_running_tasks do
        usage "tasks"
        desc  "Show the list of running tasks"
        route :task, :list_running
      end

      command :list_recent_tasks do
        usage "tasks recent [<number>]"
        desc  "Show <number> recent tasks"
        route :task, :list_recent
      end

      command :list_vms do
        usage "vms [<deployment>]"
        desc  "List all VMs that supposed to be in a deployment"
        route :vms, :list
      end

      command :cleanup do
        usage "cleanup"
        desc  "Remove all but several recent stemcells and releases " +
                  "from current director " +
                  "(stemcells and releases currently in use are NOT deleted)"
        route :maintenance, :cleanup
      end

      command :cloudcheck do
        usage  "cloudcheck"
        desc   "Cloud consistency check and interactive repair"
        option "--auto", "resolve problems automatically " +
            "(not recommended for production)"
        option "--report", "generate report only, " +
            "don't attempt to resolve problems"
        route  :cloud_check, :perform
      end

      command :upload_blob do
        usage  "upload blob <blobs>"
        desc   "Upload given blob to the blobstore"
        option "--force", "bypass duplicate checking"
        route  :blob, :upload_blob
      end

      command :sync_blobs do
        usage "sync blobs"
        desc  "Sync blob with the blobstore"
        option "--force", "overwrite all local copies with the remote blob"
        route :blob, :sync_blobs
      end

      command :blobs do
        usage "blobs"
        desc  "Print blob status"
        route :blob, :blobs_info
      end

      def define_plugin_commands
        Gem.find_files("bosh/cli/commands/*.rb", true).each do |file|
          class_name = File.basename(file, ".rb").capitalize

          next if Bosh::Cli::Command.const_defined?(class_name)

          load file

          plugin = Bosh::Cli::Command.const_get(class_name)

          plugin.commands.each do |name, block|
            command(name, &block)
          end

          @plugins ||= {}
          @plugins[class_name] = plugin
        end
      end

    end

    def parse_options!
      opts_parser = OptionParser.new do |opts|
        opts.on("-c", "--config FILE") { |file| @options[:config] = file }
        opts.on("--cache-dir DIR") { |dir|  @options[:cache_dir] = dir }
        opts.on("--verbose") { @options[:verbose] = true }
        opts.on("--no-color") { @options[:colorize] = false }
        opts.on("-q", "--quiet") { @options[:quiet] = true }
        opts.on("-s", "--skip-director-checks") do
          @options[:director_checks] = false
        end
        opts.on("-n", "--non-interactive") do
          @options[:non_interactive] = true
          @options[:colorize] = false
        end
        opts.on("-d", "--debug") { @options[:debug] = true }
        opts.on("-v", "--version") { dispatch(find_command(:version)); }
      end

      @args = opts_parser.order!(@args)
    end

    def build_parse_tree
      @parse_tree = ParseTreeNode.new

      COMMANDS.each_pair do |id, command|
        p = @parse_tree
        n_kw = command.keywords.size

        keywords = command.keywords.each_with_index do |kw, i|
          p[kw] ||= ParseTreeNode.new
          p = p[kw]
          p.command = command if i == n_kw - 1
        end
      end
    end

    def add_shortcuts
      { "st" => "status",
        "props" => "properties",
        "cck" => "cloudcheck" }.each do |short, long|
        @parse_tree[short] = @parse_tree[long]
      end
    end

    def basic_usage
      <<-OUT.gsub(/^\s{10}/, "")
          usage: bosh [--verbose] [--config|-c <FILE>] [--cache-dir <DIR]
                      [--force] [--no-color] [--skip-director-checks] [--quiet]
                      [--non-interactive]
                      command [<args>]
      OUT
    end

    def command_usage(cmd, margin = nil)
      command = cmd.is_a?(Symbol) ? find_command(cmd) : cmd
      usage = command.usage

      margin ||= 2
      usage_width = 25
      desc_width = 43
      option_width = 10

      output = " " * margin
      output << usage.ljust(usage_width) + " "
      char_count = usage.size > usage_width ? 100 : 0

      command.description.to_s.split(/\s+/).each do |word|
        if char_count + word.size + 1 > desc_width # +1 accounts for space
          char_count = 0
          output << "\n" + " " * (margin + usage_width + 1)
        end
        char_count += word.size
        output << word << " "
      end

      command.options.each do |name, value|
        output << "\n" + " " * (margin + usage_width + 1)
        output << name.ljust(option_width) + " "
        # Long option name eats the whole line,
        # short one gives space to description
        char_count = name.size > option_width ? 100 : 0

        value.to_s.split(/\s+/).each do |word|
          if char_count + word.size + 1 > desc_width - option_width
            char_count = 0
            output << "\n" + " " * (margin + usage_width + option_width + 2)
          end
          char_count += word.size
          output << word << " "
        end
      end

      output
    end

    def help_message
      template = File.join(File.dirname(__FILE__),
                           "templates", "help_message.erb")
      ERB.new(File.read(template), 4).result(binding.taint)
    end

    def plugin_help_message
      help = ['']

      @plugins.each do |class_name, plugin|
        help << class_name
        plugin.commands.keys.each do |name|
          help << command_usage(name)
        end
      end

      help.join("\n")
    end

    def search_parse_tree(node)
      return nil if node.nil?
      arg = @args.shift

      longer_command = search_parse_tree(node[arg])

      if longer_command.nil?
        @args.unshift(arg) if arg # backtrack if needed
        node.command
      else
        longer_command
      end
    end

    def try_alias
      # Tries to find best match among aliases (possibly multiple words),
      # then unwinds it onto the remaining args and searches parse tree again.
      # Not the most effective algorithm but does the job.
      config = Bosh::Cli::Config.new(
          @options[:config] || Bosh::Cli::DEFAULT_CONFIG_PATH)
      candidate = []
      best_match = nil
      save_args = @args.dup

      while arg = @args.shift
        candidate << arg
        resolved = config.resolve_alias(:cli, candidate.join(" "))
        if best_match && resolved.nil?
          @args.unshift(arg)
          break
        end
        best_match = resolved
      end

      if best_match.nil?
        @args = save_args
        return
      end

      best_match.split(/\s+/).reverse.each do |arg|
        @args.unshift(arg)
      end

      search_parse_tree(@parse_tree)
    end

    def command_suggestions(args)
      non_keywords = args - ALL_KEYWORDS

      COMMANDS.values.select do |cmd|
        (args & cmd.keywords).size > 0 && args - cmd.keywords == non_keywords
      end
    end

    def unknown_command(cmd)
      say("Command `#{cmd}' not found.")
      say("Please use `bosh help' to get the list of bosh commands.")
    end

    def save_exception(e)
      say("BOSH CLI Error: #{e.message}".red)
      begin
        errfile = File.expand_path("~/.bosh_error")
        File.open(errfile, "w") do |f|
          f.write(e.message)
          f.write("\n")
          f.write(e.backtrace.join("\n"))
        end
        say("Error information saved in #{errfile}")
      rescue => e
        say("Error information couldn't be saved: #{e.message}")
      end
    end

  end

end

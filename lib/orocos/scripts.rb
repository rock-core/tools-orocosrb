module Orocos
    # @deprecated renamed to Orocos::Scripts.watch
    #--
    # TODO move the code and test
    def self.watch(*objects, &block)
        options = Hash.new
        if objects.last.kind_of?(Hash)
            options = objects.pop
        end
        options = Kernel.validate_options options, :sleep => 0.1, :display => true, :main => nil

        tasks, ports = objects.partition do |obj|
            obj.respond_to?(:ports)
        end
        ports, readers = ports.partition do |obj|
            obj.respond_to?(:writer)
        end

        tasks = tasks.sort_by { |t| t.name }
        readers.concat(ports.map { |p| p.reader })
        readers = readers.sort_by { |r| r.port.full_name }
        readers = readers.map do |r|
            [r, r.new_sample]
        end

        dead_processes = Set.new
        
        should_quit = false
        while true
            updated_tasks = Set.new
            updated_ports = Set.new

            needs_display = true
            while needs_display
                needs_display = false
                info = tasks.map do |t|
                    if t.process && !t.process.running?
                        if !dead_processes.include?(t)
                            needs_display = true
                            updated_tasks << t
                            dead_processes << t
                            "#{t.name}=DEAD"
                        end
                    elsif t.state_changed?
                        needs_display = true
                        updated_tasks << t
                        "#{t.name}=#{t.state(false)}"
                    else
                        "#{t.name}=#{t.current_state}"
                    end
                end

                if needs_display
                    puts info.join(" | ")
                end
            end

            readers.each do |r, sample|
                while r.read_new(sample)
                    puts "new data on #{r.port.full_name}"
                    updated_ports << r.port
                    if options[:display]
                        pp = PP.new(STDOUT)
                        pp.nest(2) do
                            pp.breakable
                            sample.pretty_print(pp)
                        end
                    end
                end
            end

            if should_quit
                break
            end

            if block_given?
                should_quit = yield(updated_tasks, updated_ports) 
            end
            if options[:main]
                should_quit = !options[:main].runtime_state?(options[:main].peek_current_state)
            end
            sleep options[:sleep]
        end
    end

    # Common command-line option handling for Ruby scripts
    #
    # Its main functionality is to allow the override of run configuration with
    # command line options, such as running under gdb or valgrind
    #
    # The following command-line options are implemented:
    #
    # --host=HOSTNAME[:IP] sets the hostname and IP of the CORBA name server to
    #   connect to
    #
    # --attach do not start deployment processes given to {Scripts.run} if it
    #   appears that they are already running
    #
    # --conf-dir=DIR loads the given configuration directory
    #
    #
    # --conf=TASKNAME[:FILE],conf0,conf1 apply the configuration [conf0, conf1]
    #   to the task whose name or model name is TASKNAME. This option is handled
    #   when {Scripts.conf} is called. If TASKNAME is omitted, the configuration
    #   becomes the default for all tasks.
    #
    # --gdbserver make {Scripts.run} start everything under gdb
    #
    # --valgrind make {Scripts.run} start everything under valgrind
    #
    # @example
    #   require 'orocos'
    #   require 'orocos/scripts'
    #   options = OptionParser.new do |opt|
    #       opt.banner = "myscript [options]"
    #       Orocos::Scripts.common_optparse_setup(opt)
    #   end
    #   arguments = options.parse(ARGV)
    #   ...
    #   Orocos::Scripts.run 'my::Task' => 'task' do
    #       task = Orocos.get 'task'
    #
    #       # Replaces Orocos.apply_conf, taking into account the command
    #       # line options
    #       Orocos::Scripts.conf(task)
    #
    #       Orocos::Scripts.watch(task)
    #   end
    #   
    module Scripts
        class << self
            # If true, the script should try to attach to running tasks instead of
            # starting new ones
            attr_predicate :attach?, true
            # If true, the script should start a task browser GUI instead of
            # being headless.
            attr_predicate :gui?, true
            # The configuration specifications stored so far, as a mapping from
            # a task descriptor (either a task name or a task model name) to a
            # list of configurations to apply.
            #
            # The task name takes precedence on the model
            attr_reader :conf_setup
            attr_reader :conf_default
            # Options that should be passed to Orocos.run
            attr_reader :run_options
        end
        @conf_setup = Hash.new
        @conf_default = ['default']
        @run_options = Hash.new

        def self.common_optparse_setup(optparse)
            @attach = false
            @gui = false
            @run_options = Hash.new
            optparse.on('--host=HOSTNAME', String) do |hostname|
                Orocos::CORBA.name_service = hostname.to_str
            end
            optparse.on('--gui', "start vizkit's task inspector instead of having a text state monitoring") do
                @gui = true
            end
            optparse.on('--attach', "do not actually start the components, simply attach to running ones") do
                @attach = true
            end
            optparse.on('--conf-dir=DIR', String, "load the configuration files in this directory (not needed when using bundles)") do |conf_source|
                Orocos.conf.load_dir(conf_source)
            end
            optparse.on('--conf=TASK[:FILE],conf0,conf1', String, "load this specific configuration for the given task. The task is given by its deployed name") do |conf_setup|
                task, *conf_sections = conf_setup.split(',')
                task, *file = task.split(':')
                if !file.empty?
                    task = "#{task}:#{file[0..-2].join(":")}"
                    file = file.pop

                    if !File.file?(file)
                        raise ArgumentError, "no such file #{file}"
                    end
                else file = nil
                end
                if conf_sections.empty?
                    conf_sections = ['default']
                end
                if !task
                    @conf_default = conf_sections
                else
                    @conf_setup[task] = [file, conf_sections]
                end
            end
            optparse.on '--gdbserver', 'start the component(s) with gdb' do
                run_options[:gdb] = true
            end
            optparse.on '--valgrind', 'start the component(s) with gdb' do
                run_options[:valgrind] = true
            end
            optparse.on '--help', 'show this help message' do
                puts optparse
                exit 0
            end
        end

        def self.conf(task)
            file, sections = conf_setup[task.name] || conf_setup[task.model.name]
            sections ||= conf_default

            if file
                Orocos.apply_conf(task, file, sections, true)
            else
                Orocos.conf.apply(task, sections, true)
            end
        end

        def self.parse_stream_option(opt, type_name = nil)
            logfile, stream_name = opt.split(':')
            if !stream_name && type_name
                Pocolog::Logfiles.open(logfile).stream_from_type(type_name)
            elsif !stream_name
                raise ArgumentError, "no stream name, and no type given"
            else
                Pocolog::Logfiles.open(logfile).stream(stream_name)
            end
        end

        def self.run(*options, &block)
            deployments, models = Orocos::Process.partition_run_options(*options)

            if attach?
                deployments.delete_if do |depl, _|
                    Process.new(depl).task_names.any? do |task_name|
                        TaskContext.reachable?(task_name) # assume the deployment is started
                    end
                end
                models.delete_if do |model, task_name|
                    TaskContext.reachable?(task_name) # assume the deployment is started
                end
            end

            if deployments.empty? && models.empty?
                yield
            else
                Orocos.run(deployments.merge(models).merge(run_options), &block)
            end
        end

        # Watch for a set of tasks, ports or port readers and display information
        # about them during execution
        #
        # This method will display:
        #
        # * the current state of all the listed tasks. This display is updated only
        #   when the state of one of the tasks changed
        # * whether new data arrived on one of the ports. By default, the new
        #   samples are pretty-printed. This can be changed by setting the :display
        #   option to false
        #
        #
        # @option [Array<Port,TaskContext,Hash>] objects a list of objects to
        #   watch. The option hash, if present, needs to be put at the end of
        #   the method call, e.g.
        #
        #       Orocos::Scripts.watch(task, sleep: 0.1)
        #
        # The update period can be changed with the :sleep option. It defaults to
        # 0.1. Note that all state changes are displayed regardless of the period
        # chosen.
        #
        # If a task is given to the :main option, the loop will automatically quit
        # if that task has finished execution.
        #
        # If a block is given, it is called at each loop with the set of tasks whose
        # state changed and the set of ports which got new data (either or both can
        # be empty). This block should return true if the loop should quit and false
        # otherwise.
        def self.watch(*objects, &block)
            # TODO: move the code here and truly deprecate Orocos.watch
            Orocos.watch(*objects, &block)
        end
    end
end


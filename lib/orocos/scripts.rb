require 'orocos'

module Orocos
    module Scripts
        class << self
            # If true, the script should try to attach to running tasks instead of
            # starting new ones
            attr_predicate :attach?, true
            # The configuration specifications stored so far, as a mapping from
            # a task descriptor (either a task name or a task model name) to a
            # list of configurations to apply.
            #
            # The task name takes precedence on the model
            attr_reader :conf_setup
        end
        @conf_setup = Hash.new

        def self.common_optparse_setup(optparse)
            optparse.on('--host=HOSTNAME') do |hostname|
                Orocos::CORBA.name_service = hostname.to_str
            end
            optparse.on('--attach') do
                @attach = true
            end
            optparse.on('--conf-dir=DIR', String) do |conf_source|
                Orocos.conf.load_dir(conf_source)
            end
            optparse.on('--conf=TASK,conf0,conf1', String) do |conf_setup|
                task, *conf_sections = conf_setup.split(',')
                @conf_setup[task] = conf_sections
            end
        end

        def self.conf(task)
            setup = @conf_setup[task.name] ||
                @conf_setup[task.model.name] ||
                ['default']

            Orocos.conf.apply(task, setup)
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
            deployments, models, options = Orocos::Process.parse_run_options(*options)

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
                Orocos.run(deployments.merge(models).merge(options), &block)
            end
        end
    end
end

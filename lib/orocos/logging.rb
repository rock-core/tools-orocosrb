require 'logger'
require 'utilrb/logger'
module Orocos
    def self.log_all
        log_all_ports
        log_all_configuration
    end

    # Setup logging on all output ports of the processes started with Orocos.run
    #
    # This method is designed to be called within an Orocos.run block
    #
    # @param [nil,#===] exclude_ports an object matching the name of the ports
    #   that should not be logged (typically a regular expression). If nil, all
    #   ports are logged.
    # @param [nil,#===] exclude_types an object matching the name of the types
    #   that should not be logged (typically a regular expression). If nil, all
    #   ports are logged.
    # @param [nil,Array<String>] tasks name of the tasks for which logging
    #   should be set up
    #
    # @example log all ports whose name does not start with 'io_'
    #   Orocos.log_all_ports(exclude_ports: /^io_/)
    # @example log all ports whose type name does not contain 'debug'
    #   Orocos.log_all_ports(exclude_types: /debug/)
    #
    def self.log_all_ports(exclude_ports: nil, exclude_types: nil, tasks: nil)
        each_process do |process|
            process.log_all_ports(exclude_ports: exclude_ports, exclude_types: exclude_types, tasks: tasks)
        end
    end

    class << self
        attr_accessor :configuration_log_name
    end
    @configuration_log_name = "properties"

    # The Pocolog::Logfiles object used by default by
    # Orocos.log_all_configuration. It will automatically be created by
    # Oroocs.configuration_log if Orocos.log_all_configuration is called without
    # an argument
    attr_writer :configuration_log

    # If Orocos.configuration_log is not set, it creates a new configuration log
    # file that will be used by default by Orocos.log_all_configuration. The log
    # file is named as Orocos.configuration_log_name ('task_configuration' by
    # default). This log file becomes the new default log file for all following
    # calls to Orocos.log_all_configuration
    def self.configuration_log
        if !HAS_POCOLOG
            raise ArgumentError, "the pocolog Ruby library is not available, configuration logging cannot be used"
        end
        @configuration_log ||= Pocolog::Logfiles.create(File.expand_path(Orocos.configuration_log_name, Orocos.default_working_directory))
    end

    def self.log_all_configuration(logfile = nil)
        logfile ||= configuration_log
        each_process do |process|
            process.each_task do |t|
                t.log_all_configuration(logfile)
            end
        end
    end

    # Common implementation of log_all_ports for a single process
    #
    # This is shared by local and remote processes alike
    def self.log_all_process_ports(process, tasks: nil, exclude_ports: nil, exclude_types: nil, **logger_options)
        if !(logger = process.default_logger)
            return Set.new
        end

        process.setup_default_logger(
            logger,
            **logger_options)

        logged_ports = Set.new
        process.task_names.each do |task_name|
            task = TaskContext.get(task_name)
            next if task == logger
            next if tasks && !(tasks === task_name)

            task.each_output_port do |port|
                next if exclude_ports && exclude_ports === port.name
                next if exclude_types && exclude_types === port.type.name
                next if block_given? && !yield(port)

                Orocos.info "logging % 50s of type %s" % ["#{task.name}:#{port.name}", port.type.name]
                logged_ports << [task.name, port.name]
                logger.log(port)
            end
        end
        if !logger.running?
            logger.start
        end

        logged_ports
    end
end


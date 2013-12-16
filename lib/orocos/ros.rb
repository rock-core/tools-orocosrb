module Orocos
    module ROS
        def self.available?
            defined? TRANSPORT_ROS
        end
        def self.disable
            @enabled = false
        end
        def self.enabled?
            available? && @enabled && (ENV['ROS_MASTER_URI'] && ENV['ROCK_ROS_INTEGRATION'] != '0')
        end
        @enabled = true

        def self.default_ros_master_uri
            ENV['ROS_MASTER_URI']
        end

        # Returns the ROS name service that gives access to the master listed in
        # ROS_MASTER_URI
        #
        # @return [NameService,false] the name service object, or false if it
        #   cannot be accessed
        def self.name_service
            if @name_service
                return @name_service
            else
                ns = Orocos::ROS::NameService.new
                ns.validate
                @name_service = ns
            end
        end
    end

    if ROS.available?
        Port.transport_names[TRANSPORT_ROS] = 'ROS'
    end
end
begin
    require 'orogen_ros'
rescue LoadError
    if Orocos::ROS.available?
        Orocos.warn "ROS transport is available, but I cannot load the orogen_ros library, disabling"
        Orocos::ROS.disable
    end
end

require 'xmlrpc/client'
require 'utilrb/thread_pool'
require 'orocos/ros/rpc'
require 'orocos/ros/types'
require 'orocos/ros/name_service'
require 'orocos/ros/node'
require 'orocos/ros/topic'
require 'orocos/ros/ports'
require 'orocos/ros/name_mappings'

# If ROS_MASTER_URI is set, auto-add the name service to the default
# list. One can remove it manually afterwards.
if Orocos::ROS.enabled?
    begin
        Orocos::ROS.name_service
        Orocos.default_cmdline_arguments = Orocos.default_cmdline_arguments.merge('with-ros' => true)
        Orocos.debug "ROS integration was enabled, passing default arguments: #{Orocos.default_cmdline_arguments}"
    rescue Orocos::ROS::ComError
        Orocos.warn "ROS integration was enabled, but I cannot contact the ROS master at #{Orocos::ROS.default_ros_master_uri}, disabling"
        Orocos::ROS.disable
        Orocos.default_cmdline_arguments = Orocos.default_cmdline_arguments.delete('with-ros')
    end
end

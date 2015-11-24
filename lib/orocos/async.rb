require 'orocos'
if Orocos.initialized?
    Orocos.fatal "you cannot call Orocos.initialize before loading orocos/async"
    exit 1
end
require 'orocos/log'
require 'orocos/async/async'
require 'orocos/async/object_base'
require 'orocos/async/ports'
require 'orocos/async/attributes'
require 'orocos/async/task_context_base'
require 'orocos/async/task_context'
require 'orocos/async/name_service'
require 'orocos/async/orocos'
require 'orocos/async/task_context_proxy'
require 'orocos/async/ruby_task_context'
require 'orocos/async/log/task_context'
require 'orocos/async/log/ports'
require 'orocos/async/log/attributes'

if Orocos::ROS.available?
require 'orocos/ros/async'
end

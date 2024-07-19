begin
    require 'orogen'
rescue LoadError
    STDERR.puts "Cannot require 'orogen'"
    STDERR.puts "If you are using Rock, the 'orogen' package should have been installed automatically."
    STDERR.puts "It should be installed in tools/orogen from the root of your Rock installation"
    STDERR.puts "Make sure that you have loaded autoproj's env.sh script before continuing"
    exit 1
end

begin
    require 'orocos/rorocos'
rescue LoadError => e
    STDERR.puts "Cannot require orocos.rb's Ruby/C extension #{e}"
    STDERR.puts "If you are using Rock, this should have been done automatically."
    STDERR.puts "Run"
    STDERR.puts "  amake orocos.rb"
    STDERR.puts "and try again"
    exit 1
end

require 'typelib'
require 'orocos/base'
require 'orocos/default_loader'
require 'orocos/typekits'

begin
    require 'pocolog'
    Orocos::HAS_POCOLOG = true
rescue LoadError
    Orocos::HAS_POCOLOG = false
end

module Orocos
    OROCOSRB_LIB_DIR = File.expand_path('orocos', File.dirname(__FILE__))

    extend Logger::Root('orocos.rb', Logger::WARN)
end

require 'orogen'
require 'utilrb/module/attr_predicate'
require 'utilrb/hash/map_value'

require 'orocos/namespace'
require 'orocos/logging'
require 'orocos/version'
require 'orocos/name_service'
require 'orocos/task_context_base'
require 'orocos/task_context'
require 'orocos/ports_base'
require 'orocos/port'
require 'orocos/input_port'
require 'orocos/output_port'
require 'orocos/operations'
require 'orocos/process'
require 'orocos/corba'
require 'orocos/mqueue'

require 'orocos/component_loader'

# Updated file layout for ruby tasks
require 'orocos/ruby_tasks'
require 'orocos/input_writer'
require 'orocos/output_reader'
# This backward-compatibility code !
require 'orocos/ruby_task_context'

require 'orocos/scripts'

require 'utilrb/hash/recursive_merge'
require 'orocos/configurations'

require 'orocos/extensions'
require 'orocos/ros'

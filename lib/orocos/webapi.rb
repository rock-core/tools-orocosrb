require 'orocos'
require 'orocos/async'

require 'grape'
require 'multi_json'
require 'faye/websocket'

require 'orocos/webapi/event_loop'
require 'orocos/webapi/tasks'

module Orocos
    module WebAPI
        # Root for a REST API that allows to access a running Rock system
        class Root < Grape::API
            version 'v1'

            mount Tasks
        end
    end
end

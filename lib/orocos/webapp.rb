require 'orocos'
require 'orocos/async'

require 'grape'
require 'multi_json'
require 'faye/websocket'

require 'orocos/webapp/event_loop'
require 'orocos/webapp/tasks'

module Orocos
    module WebApp
        # Root for a REST API that allows to access a running Rock system
        class Root < Grape::API
            version 'v1'

            mount Tasks
        end
    end
end

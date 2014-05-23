require 'grape'
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

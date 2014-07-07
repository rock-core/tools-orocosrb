module Orocos
    module WebAPI
        class FloatValidator < Grape::Validations::Validator
            def validate_param!(attr_name, params)
            end
        end
        class Tasks < Grape::API
            version 'v1', using: :header, vendor: :rock
            format :json

            resource :tasks do
                desc "Lists all tasks that are currently reachable on the name services"
                params do
                    optional :extended_info, type: Boolean, default: false
                end
                get do
                    if params[:extended_info]
                        Hash[tasks: Orocos.name_service.each_task.map(&:to_h)]
                    else
                        Hash[task_names: Orocos.name_service.names]
                    end
                end

                helpers do
                    def task_by_name(name)
                        Orocos.name_service.get params[:name]
                    rescue Orocos::NotFound
                        error! "cannot find #{params[:name]} on the registered name services", 404
                    end

                    def port_by_task_and_name(name, port_name)
                        task_by_name(name).port(port_name)
                    rescue Orocos::NotFound
                        error! "cannot find port #{port_name} on task #{name}", 404
                    end
                end

                desc "Lists information about a given task"
                get ':name' do
                    Hash[task: task_by_name(params[:name]).to_h]
                end

                desc "returns information about the given port"
                get ':name/ports/:port_name' do
                    Hash[port: port_by_task_and_name(params[:name], params[:port_name]).model.to_h]
                end

                desc 'read a sample on the given port and returns it'
                params do
                    optional :timeout, type: Float, default: 2.0
                    optional :poll_period, type: Float, default: 0.05
                end
                get ':name/ports/:port_name/read' do
                    port = port_by_task_and_name(params[:name], params[:port_name])

                    reader = port.reader
                    (params[:timeout] / params[:poll_period]).ceil.times do
                        if sample = reader.raw_read
                            return Hash[:sample => sample.to_simple_value]
                        end
                        sleep params[:poll_period]
                    end
                    error! "did not get any sample from #{params[:name]}.#{params[:port_name]} in #{params[:timeout]} seconds", 408
                end
            end
        end
    end
end


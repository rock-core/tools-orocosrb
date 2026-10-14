module Orocos
    module RubyTasks
        # Facade that hides a ruby task behind an object that behaves exactly
        # like a plain TaskContext
        #
        # It is to be used in tests where it is more convenient to use RubyTasks
        # (rather than compile orogen components), but where we want to be sure
        # to only have access to the plain TaskContext API
        #
        # It only replicates the creation and destruction APIs from
        # {RubyTasks::TaskContext}
        class RemoteTaskContext < Orocos::TaskContext
            # Create a {RemoteTaskContext} based on its orogen model
            def self.from_orogen_model(name, orogen_model, register_on_name_server: true)
                ruby_task = TaskContext.from_orogen_model(name, orogen_model)
                remote_task = new(
                    ruby_task.ior,
                    name: ruby_task.name, model: ruby_task.model
                )
                remote_task.instance_variable_set(:@local_ruby_task, ruby_task)
                remote_task
            end

            # The underlying {RubyTasks::TaskContext}
            attr_reader :local_ruby_task

            # Destroys a created ruby task
            def dispose
                @local_ruby_task.dispose
            end
        end
    end
end


module Orocos
    module RobyPlugin
        class InternalError < RuntimeError; end
        class ConfigError < RuntimeError; end
        class SpecError < RuntimeError; end


        class Ambiguous < SpecError; end

        class TaskAllocationFailed < SpecError
            attr_reader :task_parents
            attr_reader :abstract_task
            def initialize(task)
                @abstract_task = task
                @task_parents = abstract_task.
                    enum_for(:each_parent_object, Roby::TaskStructure::Dependency).
                    map do |parent_task|
                        options = parent_task[abstract_task,
                            Roby::TaskStructure::Dependency]
                        [options[:roles], parent_task]
                    end
            end

            def pretty_print(pp)
                pp.text "cannot find a concrete implementation for #{abstract_task}"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(task_parents) do |parent|
                        role, parent = parent
                        pp.text "child #{role.to_a.first} of #{parent.to_short_s}"
                    end
                end
            end
        end

        class AmbiguousTaskAllocation < TaskAllocationFailed
            attr_reader :candidates

            def initialize(task, candidates)
                super(task)
                @candidates    = candidates
            end

            def pretty_print(pp)
                pp.text "there are multiple candidates to implement the abstract task #{abstract_task}"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(task_parents) do |parent|
                        role, parent = parent
                        pp.text "child #{role.to_a.first} of #{parent.to_short_s}"
                    end
                end
                pp.breakable
                pp.text "you must select one of the candidates using the 'use' statement"
                pp.breakable
                pp.text "possible candidates are"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(candidates) do |task|
                        pp.text task.to_short_s
                    end
                end
            end
        end

        class MissingDeployments < SpecError
            attr_reader :tasks

            def initialize(tasks)
                @tasks = Hash.new
                tasks.each do |task|
                    parents = task.
                        enum_for(:each_parent_object, Roby::TaskStructure::Dependency).
                        map do |parent_task|
                            options = parent_task[task,
                                Roby::TaskStructure::Dependency]
                            [options[:roles].to_a.first, parent_task]
                        end
                    @tasks[task] = parents
                end
            end

            def pretty_print(pp)
                pp.text "cannot find a deployment for the following tasks"
                tasks.each do |task, parents|
                    pp.breakable
                    pp.text task.to_s
                    pp.nest(2) do
                        pp.breakable
                        pp.seplist(parents) do |parent_task|
                            role, parent_task = parent_task
                            pp.text "child #{role} of #{parent_task}"
                        end
                    end
                end
            end
        end

        # Exception raised when the user provided a composition child selection
        # that is not compatible with the child definition
        class InvalidSelection < SpecError
            # The composition model
            attr_reader :composition_model
            # The child name for which the selection is invalid
            attr_reader :child_name
            # The model selected by the user
            attr_reader :selected_model
            # The model required by the composition for +child_name+
            attr_reader :required_models

            def initialize(composition_model, child_name, selected_model, required_models)
                @composition_model, @child_name, @selected_model, @required_models =
                    composition_model, child_name, selected_model, required_models
            end

            def pretty_print(pp)
                pp.text "cannot use #{selected_model.short_name} for the child #{child_name} of #{composition_model.short_name}"
                pp.breakable
                pp.text "it does not provide the required models"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(required_models) do |m|
                        pp.text m.short_name
                    end
                end
            end
        end
    end
end



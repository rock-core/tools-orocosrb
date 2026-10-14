
module Orocos::Async::CORBA
    class TaskContext < Orocos::Async::TaskContextBase
        # A TaskContext
        #
        # If not specified the default option settings are:
        #       :event_loop => Async.event_loop
        #       :raise => false
        #       :watchdog => true
        #       :period => 1.0
        #
        # @param [String,#ior] ior The ior of the task or a task context.
        # @param [Hash] options The options.
        # @option options [String] :name The name of the task.
        # @option options [Utilrb::EventLoop] :event_loop The event loop.
        # @option options [String] :ior The IOR
        # @option options [Boolean] :raise Raises an Orocos::NotFound error if the remote task is
        #       unreachable or went offline. Otherwise tries to reconnect and silently ignores method calls on
        #       the remote task object as long as the task is unreachable.
        # @option options [Boolean] :watchdog Checks the state of the tasks and if it is reachable.
        # @option options [Float] :period The period of the watchdog in seconds.
        # @option options [Orocos::TaskContext] :use Use the given task as designated object. After this any other other code
        #       path is not allowed to use the given task otherwise there might be multi threading problems. Furthermore
        #       it is assumed that the given task is reachable.
        # @overload initialize(options)
        # @overload initialize(task,options)
        #       @option options [#ior,#name] :task a task context.
        def initialize(ior,options=Hash.new)
            if ior.respond_to?(:ior)
                ior = ior.ior
            end
            ior,options = if ior.is_a? Hash
                              [nil,ior]
                          else
                              [ior,options]
                          end
            ior ||= if options.has_key? :ior
                        options[:ior]
                    elsif options.has_key? :use
                        options[:use].ior
                    end
            name = options[:name] || ior
            super(name,options.merge(:ior => ior))
            @ior = ior.to_str
        end

        def really_add_listener(listener)
            super

            # call new listeners with the current value
            # to prevent different behaviors depending on
            # the calling order
            if listener.use_last_value? && listener.event == :state_change
                state = @mutex.synchronize do
                    @delegator_obj.current_state if valid_delegator?
                end
                event_loop.once{listener.call state} if state
            end
        end

        def ior
            @mutex.synchronize do
                @ior.dup if @ior
            end
        end

        # (see TaskContextBase#configure_delegation)
        #
        # @option options [String] name the task name
        # @option options [String] ior the task IOR
        def configure_delegation(options = Hash.new)
            options = Kernel.validate_options options,
                :name=> nil,
                :ior => nil

            ior = options[:ior]
            @ior,@name = if valid_delegator?
                             [@delegator_obj.ior,@delegator_obj.name]
                         elsif ior.respond_to?(:ior)
                             [ior.ior, ior.name]
                         else
                             [ior, @name]
                         end

            if !@ior
                raise ArgumentError, "no IOR or task has been given"
            end
        end

        def respond_to_missing?(method_name, include_private = false)
            @delegator_obj&.respond_to?(method_name) || super
        end

        def method_missing(m,*args)
            if respond_to_missing?(m)
                event_loop.sync(@delegator_obj,args) do |args|
                    @delegator_obj.method(m).call(*args)
                end
            else
                super
            end
        end

        private

        # Called by #task_context to create the underlying task context object
        def access_remote_task_context
            Orocos::TaskContext.new @ior ,:name => @name
        end

        # add methods which forward the call to the underlying task context
        forward_to :task_context,:@event_loop, :known_errors => Orocos::Async::KNOWN_ERRORS,:on_error => :emit_error do
            methods = Orocos::TaskContext.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
            methods -= Orocos::Async::CORBA::TaskContext.instance_methods + [:method_missing]
            def_delegators methods
        end
    end
end

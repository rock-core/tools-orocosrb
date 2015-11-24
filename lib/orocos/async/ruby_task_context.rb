
module Orocos::Async

    # Class for writing ruby tasks supporting async API
    #
    # Example:
    # class MyTask < Orocos::Async::RubyTasks::TaskContext
    #     def initialize(name="camera")
    #         # generate a ruby tasks having a camera interface
    #         super(name,'camera_prosilica::Task',:period => 10)
    #     end
    #
    #     # configure hook
    #     def configure_hook
    #     end
    #
    #     # start hook
    #     def start_hook
    #     end
    #
    #     # update hook
    #     def update_hook
    #     end
    #
    #     # stop hook
    #     def stop_hook
    #     end
    #
    #     # error hook
    #     def error_hook
    #     end
    # end
    # task = MyTask.new
    # task.configure
    # task.start
    #
    class RubyTasks
        class LocalOutputPort < Orocos::Async::ObjectBase
            extend Forwardable

            def initialize(port,options=Hash.new)
                @options = Kernel.validate_options options,:event_loop => Orocos::Async.event_loop
                super(port.name,@options[:event_loop])
                @options = options
                reachable!(port)
            end

            methods = Orocos::RubyTasks::LocalOutputPort.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
            methods -= LocalOutputPort.instance_methods + [:method_missing,:name]
            def_delegators :@delegator_obj,*methods

            alias :write_no_check :write
            def write(sample,&block)
                # ignore writes if the task is not running
                # otherwise this might be dangerous if a control
                # task is still sending data after it was stopped
                return if !task.running?
                write_no_check(sample,&block)
            end
        end

        class LocalInputPort < Orocos::Async::ObjectBase
            extend Utilrb::EventLoop::Forwardable
            extend Orocos::Async::ObjectBase::Periodic::ClassMethods
            include Orocos::Async::ObjectBase::Periodic

            define_events :data,:raw_data
            attr_reader :raw_last_sample
            self.default_period = 0.1

            def initialize(port,options=Hash.new)
                @options = Kernel.validate_options options, :period => default_period,:event_loop => Orocos::Async.event_loop
                super(port.name,@options[:event_loop])
                @raw_last_sample = nil

                @poll_timer = @event_loop.async_every(method(:raw_read_new), {:period => period, :start => false,
                                                                              :known_errors => Orocos::Async::KNOWN_ERRORS}) do |data,error|
                    if error
                        @poll_timer.cancel
                        self.period = @poll_timer.period
                        @event_loop.once do
                            event :error,error
                        end
                    elsif data
                        @raw_last_sample = data
                        event :raw_data, data
                        event :data, Typelib.to_ruby(data)
                    end
                end
                @poll_timer.doc = port.full_name
                reachable!(port)
            rescue Orocos::NotFound => e
                emit_error e
            end

            def last_sample
                if @raw_last_sample
                    Typelib.to_ruby(@raw_last_sample)
                end
            end

            def reachable!(port,options = Hash.new)
                super
                if number_of_listeners(:raw_data) != 0
                    @poll_timer.start period unless @poll_timer.running?
                end
            end

            def period=(period)
                super
                @poll_timer.period = self.period
            end

            def really_add_listener(listener)
                if listener.event == :data
                    @poll_timer.start(period) unless @poll_timer.running?
                    listener.call Typelib.to_ruby(@raw_last_sample) if @raw_last_sample && listener.use_last_value?
                elsif listener.event == :raw_data
                    @poll_timer.start(period) unless @poll_timer.running?
                    listener.call @raw_last_sample if @raw_last_sample && listener.use_last_value?
                end
                super
            end

            def remove_listener(listener)
                super
                if number_of_listeners(:data) == 0 && number_of_listeners(:raw_data) == 0
                    @poll_timer.cancel
                end
            end

            private
            forward_to :@delegator_obj,:@event_loop,:known_errors => Orocos::Async::KNOWN_ERRORS,:on_error => :emit_error  do
                methods = Orocos::RubyTasks::LocalInputPort.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
                methods -= Orocos::Async::RubyTasks::LocalInputPort.instance_methods
                def_delegators methods
            end
        end

        class TaskContext < Orocos::Async::TaskContextBase
            extend Utilrb::EventLoop::Forwardable
            extend Orocos::Async::ObjectBase::Periodic::ClassMethods
            include Orocos::Async::ObjectBase::Periodic

            self.default_period = 0.1
            def initialize(name,model=nil,options=Hash.new)
                # get model
                model = if model.respond_to?(:name)
                            model
                        elsif model
                            Orocos.default_loader.task_model_from_name(model)
                        end

                #create ruby tasks
                ruby_task = if(model)
                                Orocos::RubyTasks::TaskContext.from_orogen_model(name,model)
                            else
                                Orocos::RubyTasks::TaskContext.new(name)
                            end

                # initialize async layer
                ruby_task = Orocos::Async::CORBA::TaskContext.new(nil,:use => ruby_task,:watchdog => true,:wait => true)

                options[:wait] = true           # this is polling the state of the underlying c++ tasks
                options[:use] = ruby_task       # use ruby task instead of getting it from the name service
                super(name,options)

                @ports = Hash.new
                @options[:period] = options[:period] || Orocos::Async::RubyTasks::TaskContext.default_period
                @hook_timer = @event_loop.every(period,false) do
                    if runtime_error?
                        error_hook
                    elsif running?
                        update_hook
                    else
                    end
                end

                on_state_change do |state|
                    if runtime_state?(state)
                        if !@hook_timer.running?
                            start_hook
                            @hook_timer.start
                        end
                    elsif state == :PRE_OPERATIONAL
                        @hook_timer.cancel if @hook_timer.running?
                        configure_hook
                    else
                        if @hook_timer.running?
                            @hook_timer.cancel
                            stop_hook
                        end
                    end
                end

                self
            end

            def configure_hook
            end

            def update_hook
            end

            def error_hook
            end

            def start_hook
            end

            def stop_hook
            end

            def dispose
                obj = @delegator_obj
                unreachable!
                obj.dispose
            end

            def unreachable!
                if @hook_timer.running?
                    @hook_timer.cancel
                    emit_stop_hook
                end
                @ports.values.map &:unreachable!
                @ports.clear
                super
            end

            def method_missing(m, *args) # :nodoc:
                m = m.to_s
                if has_port?(m)
                    if !args.empty?
                        raise ArgumentError, "expected zero arguments for #{m}, got #{args.size}"
                    end
                    return port(m)
                elsif has_property?(m) || has_attribute?(m)
                    if !args.empty?
                        raise ArgumentError, "expected zero arguments for #{m}, got #{args.size}"
                    end
                    prop = if has_property?(m) then property(m)
                           else attribute(m)
                           end
                    value = prop.read
                    if block_given?
                        yield(value)
                        prop.write(value)
                    end
                    return value
                end
                super(m.to_sym,*args)
            end

        private
            def access_remote_task_context
                @delegator_obj
            end

            # add methods which forward the call to the underlying task context
            forward_to :task_context,:@event_loop, :known_errors => Orocos::Async::KNOWN_ERRORS,:on_error => :emit_error do
                methods = Orocos::RubyTasks::TaskContext.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
                methods -= Orocos::Async::RubyTasks::TaskContext.instance_methods
                def_delegators methods
            end
        end
    end
end

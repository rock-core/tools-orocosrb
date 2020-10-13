module Orocos::Async
    class TaskContextBase < Orocos::Async::ObjectBase
        extend Utilrb::EventLoop::Forwardable
        extend Orocos::Async::ObjectBase::Periodic::ClassMethods
        include Orocos::Async::ObjectBase::Periodic

        self.default_period = 1.0

        define_events :port_reachable,
                      :port_unreachable,
                      :property_reachable,
                      :property_unreachable,
                      :attribute_reachable,
                      :attribute_unreachable,
                      :state_change

        # Creates a {RubyTasks::TaskContext} on which all values passed to the
        # given task should be mirrored
        #
        # @return [RubyTasks::TaskContext]
        def self.to_ruby(task)
            begin
                t = Orocos::CORBA.name_service.get(task.basename)
                raise "Cannot create ruby task for #{task.name} "\
                    "because there is already a task #{t.name} "\
                    "registered on the main CORBA name service."
            rescue Orocos::NotFound
            end
            t = Orocos::RubyTasks::TaskContext.new(task.basename)
            task.on_port_reachable do |port|
                next if t.has_port?(port)
                port = task.port(port)
                port.wait
                p = t.create_output_port(port.name,port.type)
                port.on_data do |data|
                    p.write data
                end
            end
            task.on_property_reachable do |prop|
                next if task.has_property?(prop)
                prop = task.property(prop)
                prop.wait
                p = @ruby_task_context.create_property(prop.name,prop.type)
                p.write p.new_sample.zero!
                prop.on_change do |data|
                    p.write data
                end
            end
            t.configure
            t.start
            t
        end

        # @!attribute raise_on_access_error?
        #   If set to true, #task_context will raise whenever the access to the
        #   remote task context failed. Otherwise, the exception will  be
        #   returned by the method
        attr_predicate :raise_on_access_error?, true

        def initialize(name,options=Hash.new)
            event_loop,reachable_options = Kernel.filter_options options,:event_loop => Orocos::Async.event_loop
            super(name,event_loop[:event_loop])
            @mutex = Mutex.new
            @last_state = nil
            @port_names = Array.new
            @property_names = Array.new
            @attribute_names = Array.new

            watchdog_proc = Proc.new do
                # this is used to disconnect the task by an error handler
                [states,port_names,property_names,attribute_names]
            end

            @watchdog_timer = @event_loop.async_every(watchdog_proc,{:period => 5,
                                                      :default => [[],[],[],[]],
                                                      :start => false,
                                                      :sync_key => nil, #is blocked by the methods call ping, states, etc
                                                      :known_errors => Orocos::Async::KNOWN_ERRORS}) do |data,error|
                                                            process_states(data[0])
                                                            process_port_names(data[1])
                                                            process_property_names(data[2])
                                                            process_attribute_names(data[3])
                                                      end
            @watchdog_timer.doc = name
            reachable!(reachable_options)
        end

        def to_async(options=Hash.new)
            self
        end

        def to_proxy(options=Hash.new)
            Orocos::Async.proxy(name,options)
        end

        # Create a ruby task on which all received data is mirrored
        #
        # This task context is unique, i.e. the same object will be returned by
        # subsequent calls to this method.
        #
        # @return [RubyTasks::TaskContext]
        def to_ruby
            @ruby_task_context ||= TaskContextBase.to_ruby(self)
        end

        # Tests whether a mirroring task has been created with
        # {ruby_task_context}
        #
        # @return [Boolean]
        def ruby_task_context?
            !!@ruby_task_context
        end

        def really_add_listener(listener)
            return super unless listener.use_last_value?

            # call new listeners with the current value
            # to prevent different behaviors depending on
            # the calling order
            if listener.event == :port_reachable
                names = @port_names.dup
                event_loop.once do 
                    names.each do |name|
                        listener.call name
                    end
                end
            elsif listener.event == :property_reachable
                names = @property_names.dup
                event_loop.once do
                    names.each do |name|
                        listener.call name
                    end
                end
            elsif listener.event == :attribute_reachable
                names = @attribute_names.dup
                event_loop.once do
                    names.each do |name|
                        listener.call name
                    end
                end
            end
            super
        end

        def name
            @mutex.synchronize do
                @name.dup if @name
            end
        end

        # Initiates the binding of the underlying sychronous access object to
        # this async object.
        #
        # It can either be directly given an object, or be asked to
        # (asynchronously) query it.
        #
        # @option options [Boolean] watchdog (true) if true, start a watchdog
        #   timer that monitors the availability of the task context
        # @option options [Float] period (default_period) the period for the
        #   watchdog (if enabled)
        # @option options [Boolean] wait (false) if true, reachable! will return
        #   only when the task has successfully been found
        # @option options [Object] use (nil) if set, this is the object we will
        #   use as underlying sychronous object. Otherwise, #task_context is
        #   going to be used to find it.
        # @option options [Boolean] raise (false) if set, the #task_context
        #   method will raise if the task context cannot be accessed on first
        #   try. Otherwise, it will try to access it forever until it finds it.
        def reachable!(options = Hash.new)
            @mutex.synchronize do
                options, configure_options = Kernel.filter_options options,
                    :watchdog => true,
                    :period => default_period,
                    :wait => false,
                    :use => nil,
                    :raise => false

                self.raise_on_access_error = options[:raise]

                if options[:use]
                    @delegator_obj = options[:use]
                    @watchdog_timer.doc = @delegator_obj.name
                else
                    invalidate_delegator!
                end

                configure_delegation(configure_options)

                @watchdog_timer.start(options[:period],false) if options[:watchdog]
                @event_loop.async(method(:task_context))
            end
            wait if options[:wait]
        end

        # Called by #reachable! to do subclass-specific configuration
        #
        # @param [Hash] configure_options all options passed to #reachable! that
        #   are not understood by #reachable!
        def configure_delegation(configure_options = Hash.new)
        end

        # Disconnectes self from the remote task context and returns its underlying
        # object used to communicate with the remote task (designated object).
        # 
        # Returns nil if the TaskContext is not connected.
        # Returns an EventLoop Event if not called from the event loop thread.
        #
        # @param [Exception] reason The reason for the disconnect
        # @return [Orocos::TaskContext,nil,Utilrb::EventLoop::Event]
        def unreachable!(options = Hash.new)
            options = Kernel.validate_options options, :error
            # ensure that this is always called from the
            # event loop thread
            @event_loop.call do
                old_task = @mutex.synchronize do
                    if valid_delegator?
                        @access_error = options.delete(:error) ||
                            ArgumentError.new("cannot access the remote task context for an unknown reason")
                        task = @delegator_obj
                        invalidate_delegator!
                        @watchdog_timer.cancel if @watchdog_timer
                        task
                    end
                end
                clear_interface
                event :unreachable if old_task
                old_task
            end
        end

        def clear_interface
            process_port_names
            process_attribute_names
            process_property_names
        end

        def reachable?(&block)
            if block
                ping(&block)
            else
                ping
            end
            true
        rescue Orocos::NotFound,Orocos::ComError => e
            unreachable!(:error => e)
            false
        end

        # Helper method to setup async calls
        #
        # Asynchronous calls can be called either with a callback or without. In
        # the first case, the callback gets called later and the method returns
        # right aways, otherwise the method get synchronously called. For
        # synchronization reasons, even the synchronous call goes through the
        # event loop (since the event loop avoids reentrant calls using the sync
        # key).
        #
        # This method is the common setup for this scheme. It uses the fact that
        # all non-async objects must provide a #to_async call to create a
        # corresponding asynchronous-access object.
        #
        # @param [Symbol] method_name the method that should be called
        # @param [Proc,nil] user_callback the user-provided callback if there is
        #   one
        # @param [Hash] to_async_options the options that should be passed to
        #   to_async
        # @param [Array] the arguments that should be forwarded to the underlying
        #   method
        #
        # @return [Object] in the synchronous case, the method returns the
        #   underlying method's return value. In the asynchronous case TODO
        def call_with_async(method_name,user_callback,to_async_options,*args)
            p = proc do |object,error|
                async_object = object.to_async(Hash[:use => self].merge(to_async_options))
                if user_callback
                    if user_callback.arity == 2
                        user_callback.call(async_object,error)
                    else
                        user_callback.call(async_object)
                    end
                else
                    async_object
                end
            end
            if user_callback
                send(method_name,*args,&p)
            else
                async_object = send(method_name,*args)
                p.call async_object,nil
            end
        end

        def attribute(name,options = Hash.new,&block)
            call_with_async(:orig_attribute,block,options,name)
        end

        def property(name,options = Hash.new,&block)
            call_with_async(:orig_property,block,options,name)
        end

        def port(name, verify = true,options=Hash.new, &block)
            call_with_async(:orig_port,block,options,name,verify)
        end

        # call-seq:
        #  task.each_property { |a| ... } => task
        # 
        # Enumerates the properties that are available on
        # this task, as instances of Orocos::Attribute
        def each_property(&block)
            if !block_given?
                return enum_for(:each_property)
            end
            property_names.each do |name|
                yield(property(name))
            end
            self
        end

        # call-seq:
        #  task.each_attribute { |a| ... } => task
        # 
        # Enumerates the attributes that are available on
        # this task, as instances of Orocos::Attribute
        def each_attribute(&block)
            if !block_given?
                return enum_for(:each_attribute)
            end
            attribute_names.each do |name|
                yield(attribute(name))
            end
            self
        end

        # call-seq:
        #  task.each_port { |p| ... } => task
        # 
        # Enumerates the ports that are available on this task, as instances of
        # either Orocos::InputPort or Orocos::OutputPort
        def each_port(&block)
            if !block_given?
                return enum_for(:each_port)
            end
            port_names.each do |name|
                yield(port(name))
            end
            self
        end

        private
        # add methods which forward the call to the underlying task context
        forward_to :task_context,:@event_loop, :known_errors => Orocos::Async::KNOWN_ERRORS,:on_error => :emit_error do
            thread_safe do
                def_delegator :ping,:known_errors => nil  #raise if there is an error in the communication
                methods = [:has_operation?, :has_port?,:property_names,:attribute_names,:port_names,:rtt_state]
                def_delegators methods
                def_delegator :reachable?, :alias => :orig_reachable?
            end
            def_delegator :port, :alias => :orig_port
            def_delegator :property, :alias => :orig_property
            def_delegator :attribute, :alias => :orig_attribute

            methods = Orocos::TaskContextBase.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
            methods -= Orocos::Async::TaskContextBase.instance_methods + [:method_missing]
            def_delegators methods
        end

        # must be called from the event loop thread
        def process_states(states=[])
            if !states.empty?
                # We don't use #event here. The callbacks, when using #event,
                # would be called delayed and therefore task.state would not be
                # equal to the state passed to the callback
                blocks = listeners :state_change
                states.each do |s|
                    next if @last_state == s
                    @last_state = s
                    blocks.each do |b|
                        b.call(s)
                    end
                end
            end
        end

        # must be called from the event loop thread
        def process_port_names(port_names=[])
            added_ports = port_names - @port_names
            deleted_ports = @port_names - port_names
            deleted_ports.each do |name|
                @port_names.delete name
                process_event :port_unreachable, name
            end
            added_ports.each do |name|
                @port_names << name
                process_event :port_reachable, name
            end
        end

        # must be called from the event loop thread
        def process_property_names(property_names=[])
            added_properties = property_names - @property_names
            deleted_properties = @property_names - property_names
            deleted_properties.each do |name|
                @property_names.delete name
                event :property_unreachable, name
            end
            added_properties.each do |name|
                @property_names << name
                process_event :property_reachable, name
            end
        end

        # must be called from the event loop thread
        def process_attribute_names(attribute_names=[])
            added_properties = attribute_names - @attribute_names
            deleted_properties = @attribute_names - attribute_names
            deleted_properties.each do |name|
                @attribute_names.delete name
                process_event :attribute_unreachable, name
            end
            added_properties.each do |name|
                @attribute_names << name
                process_event :attribute_reachable, name
            end
        end

        # Returns the designated object and an error object.
        # This must be thread safe as it is called from the worker threads!
        # the @delegator_obj instance variable must not be directly accessed
        # without proper synchronization.
        def task_context
            @mutex.synchronize do
                begin
                    task = if valid_delegator?
                               @delegator_obj
                           elsif @access_error # do not try again
                               raise @access_error
                           else
                               obj = access_remote_task_context
                               @name = obj.name
                               @watchdog_timer.doc = @name
                               port_names = obj.port_names
                               property_names = obj.property_names
                               attribute_names = obj.attribute_names
                               state = obj.state
                               @event_loop.once do
                                   process_states([state])
                                   process_port_names(port_names)
                                   process_property_names(property_names)
                                   process_attribute_names(attribute_names)
                               end
                               @delegator_obj = obj
                               event :reachable
                               obj
                           end
                    [task,nil]
                rescue Exception => e
                    @access_error = e
                    invalidate_delegator!
                    raise e if raise_on_access_error?   # do not be silent if
                    [nil,@access_error]
                end
            end
        end
    end
end


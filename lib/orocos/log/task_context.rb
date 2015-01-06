
module Orocos
    module Log
	# Exception if a port can not be initialized
	class InitializePortError < RuntimeError
	    def initialize( message, name )
		super( message )
		@port_name = name
	    end

	    attr_reader :port_name
	end

        # Simulates an output port based on log files.
        # It has the same behavior like an OutputReader
        class OutputReader
            #Handle to the port the reader is reading from
            attr_reader :port

            attr_reader :policy

            #filter for log data 
            #the filter is applied during read
            #the buffer is not effected 
            attr_accessor :filter

            #Creates a new OutputReader
            #
            #port => handle to the port the reader shall read from
            #policy => policy for reading data 
            #
            #see project orocos.rb for more information
            def initialize(port,policy=default_policy)
                @policy = default_policy if !policy
                @port = port
                @buffer = Array.new
                @filter, policy = Kernel.filter_options(policy,[:filter])
                @filter = @filter[:filter]
                policy = Orocos::Port.prepare_policy(policy)
                @policy_type = policy[:type]
                @buffer_size = policy[:size]
                @last_update = Time.now
            end

            #This method is called each time new data are availabe.
            def update(data) 
                if @policy_type == :buffer
                    @buffer.shift if @buffer.size == @buffer_size
                    @buffer << data
                end
            end

            #Clears the buffer of the reader.
            def clear_buffer 
                @buffer.clear
            end

            def connected?
                true
            end

            #Reads data from the associated port.
            def read(sample =nil)
                if @policy_type == :data
                  @last_update = port.last_update
                  return @filter.call(port.read) if @filter
                  return port.read
                elsif @policy_type == :buffer
                  sample = @buffer.shift
                  if sample
                    return @filter.call(sample) if @filter
                    return sample
                  else
                    @last_update = port.last_update
                    return nil
                  end
                else
                    raise "Port policy #{@policy_type} is not supported."
                end
            end

            def raw_read(sample)
                sample = read(sample)
                Typelib::from_ruby(sample,type) if sample
            end

            def type_name
                @port.type_name
            end
           
            #Reads data from the associated port.
            #Return nil if no new data are available
            def read_new(sample = nil)
              return nil if @last_update == port.last_update 
              read
            end

            def new_sample
                @port.new_sample
            end

            def doc?
                false
            end
        end

        #Simulates a port based on log files
        #It has the same behavior like Orocos::OutputPorts
        class OutputPort

            #true -->  this port shall be replayed even if there are no connections
            attr_accessor :tracked         

            #name of the recorded port
            attr_reader :name 

            #name of the type as Typelib::Type object           
            attr_reader :type          

            #name of the type as it is used in ruby
            attr_reader :type_name      

            #connections between this port and InputPort ports that support a writer
            attr_reader :connections    

            #dedicated stream for simulating the port
            attr_reader :stream         

            #parent log task
            attr_reader :task          

            #number of readers which are using the port
            attr_reader :readers        

            #returns the system time when the port was updated with new data
            attr_reader :last_update

            attr_reader :current_data

            #filter for log data
            #the filter is applied before all connections and readers are updated 
            #if you want to apply a filter only for one connection or one reader do not set 
            #the filter here.
            #the filter must be a proc, lambda, method or object with a function named call.
            #the signature must be:
            #new_massage call(old_message)
            attr_accessor :filter

            class << self
              attr_accessor :default_policy
            end
            self.default_policy = Hash.new
            self.default_policy[:type] = :data

            #Defines a connection which is set through connect_to
            class Connection #:nodoc:
                attr_accessor :port,:writer,:filter
                def initialize(port,policy=Hash.new)
                    @port = port
                    policy =  OutputPort::default_policy if !policy
                    @filter, policy = Kernel.filter_options(policy,[:filter])
                    @filter = @filter[:filter]
                    @writer = port.writer(policy)
                end

                def update(data)
                  if @filter 
                    @writer.write(@filter.call data)
                  else
                    @writer.write(data)
                  end
                end
            end
            
            #Defines a connection which is set through connect_to
            class CodeBlockConnection #:nodoc:
                def initialize(port_name,code_block)
                    @code_block = code_block
                    @port_name = port_name
                end
                def update(data)
                    @code_block.call data,@port_name
                end
            end

            def orocos_type_name
                if metadata && metadata.has_key?(:rock_orocos_type_name)
                    metadata[:rock_orocos_type_name]
		elsif type_name =~ /^(.*)_m$/
		    $1
                else
                    type_name
                end
            end

            #if force_local? returns true this port will never be proxied by an orogen port proxy
            def force_local?
                return true
            end

            def last_sample_pos
                task.log_replay.last_sample_pos stream
            end

            def first_sample_pos 
                task.log_replay.first_sample_pos stream
            end

            def to_orocos_port
                self
            end

            def filter(&block)
                if block
                    self.filter = block
                else
                    @filter
                end
            end

            def filter=(filter)
                @filter = filter
                self.tracked=true
            end

            #Pretty print for OutputPort.
	    def pretty_print(pp)
                pp.text "#{task.name}.#{name}"
		pp.nest(2) do
		    pp.breakable
		    pp.text "tracked = #{@tracked}"
		    pp.breakable
		    pp.text "readers = #{@readers.size}"
		    pp.breakable
		    pp.text "filtered = #{(@filter!=nil).to_s}"
		    @connections.each do |connection|
			pp.breakable
                        if connection.is_a?(OutputPort::Connection)
                          pp.text "connected to #{connection.port.task.name}.#{connection.port.name} (filtered = #{(connection.filter!=nil).to_s})"
                        end
                        if connection.is_a?(OutputPort::CodeBlockConnection)
                          pp.text "connected to code block"
                        end
		    end
		end
            end

            #returns the metadata associated with the underlying stream
            def metadata
                stream.metadata
            end

            # Give the full name for this port. It is the stream name.
            def full_name
                stream.name
            end

            #Creates a new object of OutputPort
            #
            #task => simulated task for which the port shall be created
            #stream => stream from which the port shall be created 
            def initialize(task,stream)
                if !stream.respond_to?(:name) || !stream.respond_to?(:type) || !stream.respond_to?(:typename) || !stream.respond_to?(:metadata)
                    raise "Cannot create OutputPort out of #{stream.class}"
                end
                @stream = stream
                @name = if stream.metadata.has_key? "rock_task_object_name"
                            name = stream.metadata["rock_task_object_name"]
                            if !name || name.empty?
                                name = "#{stream.name.to_s}"
                                Log.warn "Stream name (#{stream.name}) has empty meta data assuming as PORTNAME \"#{name}\""
                            end
                            name
                        else
                            # backward compatibility
                            name = stream.name.to_s.match(/\.(.*$)/)
                            if name == nil
                                name = "#{stream.name.to_s}"
                                Log.warn "Stream name (#{stream.name}) does not follow the convention TASKNAME.PORTNAME, assuming as PORTNAME \"#{name}\""
                                name
                            else
                                name[1]
                            end
                        end
		begin
		    @type = stream.type
		rescue Exception => e
		    raise InitializePortError.new( e.message, @name )
		end
                @type_name = stream.typename
                @task = task
                @connections = Array.new
                @current_data = nil
                @tracked = false
                @readers = Array.new
                @last_update = Time.now
            end

            #Creates a new reader for the port.
            def reader(policy = OutputPort::default_policy,&block)
                policy[:filter] = block if block
                self.tracked = true
                new_reader = OutputReader.new(self,policy)
                @readers << new_reader
                return new_reader
            end

            #Returns true if the port has at least one connection or 
            #tracked is set to true.
            def used?
                return @tracked
            end

            #Returns the current sample data.
            def read()
                raise "Port #{@name} is not replayed. Set tracked to true or use a port reader!" unless used? 
                return yield @current_data if block_given?
                return @current_data
            end

            def raw_read()
                sample = read()
                Typelib::from_ruby(sample,type) if sample
            end

            #If set to true the port is replayed.  
            def tracked=(value)
                raise "can not track unused port #{stream.name} after the replay has started" if !used? && aligned?
                @tracked = value
            end

            # Calls the provided block when data is replayed into this port
            def on_data(&block)
                self.tracked = true
                @connections << CodeBlockConnection.new(@name,block)
            end

            #Register InputPort which is updated each time write is called
            def connect_to(port=nil,policy = OutputPort::default_policy,&block)
                port = if port.respond_to? :find_input_port
                           #assuming port is a TaskContext
                           if !(result = port.find_input_port(type,nil))
                               raise NotFound, "port #{name} does not match any port of the TaskContext #{port.name}."
                           end
                           result.to_orocos_port
                       elsif port
                           port.to_orocos_port 
                       end

                if block && !port
                    Orocos::Log.warn "connect_to to a code block { |data| ... } is deprecated. Use #on_data instead."
                end

                self.tracked = true
                policy[:filter] = block if block
                if !port 
                  raise "Cannot set up connection no code block or port is given" unless block
                  @connections << CodeBlockConnection.new(@name,block)
                else
                  raise "Cannot connect to #{port.class}" if(!port.instance_of?(Orocos::InputPort))
                  @connections << Connection.new(port,policy)
                  Log.info "setting connection: #{task.name}.#{name} --> #{port.task.name}.#{port.name}"
                end
            end

            #Feeds data to the connected ports and readers
            def write(data)
                @last_update = Time.now
                @current_data = @filter ? @filter.call(data) : data
                if @filter && data.class != @current_data.class 
                    Log.error "Filter block for port #{full_name} returned #{@current_data.class.name} but #{data.class.name} was expected."
                    Log.error "If a statement like #{name} do |sample,port| or #{name}.connect_to(port) do |sample,port| is used, the code block always needs to return 'sample'!"
                    Log.error "Disabling Filter for port #{full_name}"
                    @filter = nil
                    @current_data = data
                end
                @connections.each do |connection|
                    connection.update(@current_data)
                end
                @readers.each do |reader|
                    reader.update(@current_data)
                end
            end

            #Disconnects all ports and deletes all readers 
            def disconnect_all
                @connections.clear
                @readers.clear
            end

            #Returns a new sample object
            def new_sample
                @type.new
            end

            #Clears all reader buffers 
            def clear_reader_buffers
                @readers.each do |reader|
                    reader.clear_buffer
                end
            end

            # returns true if Log::Replay is aligned
            def aligned?
                task.log_replay.aligned?
            end

            #Returns the number of samples for the port.
            def number_of_samples
                return @stream.size
            end

            def doc?
                false
            end

            def output?
                true
            end
        end
        
        #Simulated Property based on a configuration log file
        #It is automatically replayed if at least one OutputPort of the task is replayed
        class Property
            #true -->  this property shall be replayed
            attr_accessor :tracked
            # The underlying TaskContext instance
            attr_reader :task
            # The property/attribute name
            attr_reader :name
            # The attribute type, as a subclass of Typelib::Type
            attr_reader :type
            #dedicated stream for simulating the port
            attr_reader :stream
            attr_reader :type_name

            def initialize(task, stream)
                if !stream.respond_to?(:name) || !stream.respond_to?(:type) || !stream.respond_to?(:typename) || !stream.respond_to?(:metadata)
                    raise "Cannot create Property out of #{stream.class}"
                end
                @stream = stream
                @name = stream.name.to_s.match(/\.(.*$)/)
                raise 'Stream name does not follow the convention TASKNAME.PROPERTYNAME' if @name == nil
                @name = @name[1]
                @type = stream.type
                @task = task
                @current_value = nil
                @type_name = stream.typename
                @notify_blocks =[]
            end

            #If set to true the port is replayed.
            def tracked=(value)
                raise "can not track property #{stream.name} after the replay has started" if !used? && aligned?
                @tracked = value
            end

            # returns true if Log::Replay is aligned
            def aligned?
                task.log_replay.aligned?
            end

            def doc?
                false
            end

            # Read the current value of the property/attribute
            def read
                @current_value
            end

            def raw_read()
                sample = read()
                Typelib::from_ruby(sample,type) if sample
            end

            # Sets a new value for the property/attribute
            def write(value)
                @current_value = value
                @notify_blocks.each &:call
            end

            # registers a code block which will be called 
            # when the property changes
            def on_change(&block)
                self.tracked = true
                notify do
                    block.call(read)
                end
            end

            # registers a code block which will be called 
            # when the property changes
            def notify(&block)
                @notify_blocks << block
            end

            def new_sample
                type.new
            end

            def orocos_type_name
                if metadata && metadata.has_key?(:rock_orocos_type_name)
                    metadata[:rock_orocos_type_name]
                else
                    type_name
                end
            end

            #Returns the number of samples for the property.
            def number_of_samples
                return @stream.size
            end

            # Give the full name for this property. It is the stream name.
            def full_name
                stream.name
            end

            def pretty_print(pp) # :nodoc:
                pp.text "property #{name} (#{type.name})"
            end

            #returns the metadata associated with the underlying stream
            def metadata
                stream.metadata
            end

            def used?
                tracked
            end
        end

        #Simulates task based on a log file.
        #Each stream is modeled as one OutputPort which supports the connect_to method
        class TaskContext < Orocos::TaskContextBase
            include Namespace
            attr_reader :file_path             #path of the dedicated log file
            attr_reader :file_path_config      #path of the dedicated log configuration file
            attr_reader :log_replay

            #Creates a new instance of TaskContext.
            #
            #* task_name => name of the task
            #* file_path => path of the log file
            def initialize(log_replay,task_name,file_path,file_path_config)
                super(task_name)
                self.model = Orocos::Spec::TaskContext.new(Orocos.master_project, '')
                @log_replay = log_replay
                @invalid_ports = Hash.new # ports that could not be loaded
                @file_path = file_path
                @file_path_config = nil
                @file_path_config_reg = file_path_config
                @rtt_state = :RUNNING
                @port_reachable_blocks = Array.new
                @property_reachable_blocks = Array.new
                @state_change_blocks = Array.new
            end

            def current_state=(val)
                @current_state=val
                @state_change_blocks.each do |b|
                    b.call val
                end
            end

            def on_state_change(&block)
                @state_change_blocks << block
            end

            def to_s
                "#<Orocos::Log::TaskContext: #{name}>"
            end

            def rename(name)
                @name = name
            end

            def on_port_reachable(&block)
                @port_reachable_blocks << block
            end

            def on_property_reachable(&block)
                @property_reachable_blocks << block
            end


            # Returns the array of the names of available properties on this task
            # context
            def property_names
                @properties.values.map(&:name)
            end

            # Returns the array of the names of available attributes on this task
            # context
            def attribute_names
                Array.new
            end

            # Returns the array of the names of available operations on this task
            # context
            def operation_names
                Array.new
            end

            # Returns the names of all the ports defined on this task context
            def port_names
                @ports.keys
            end

            # Reads the state
            def rtt_state
                @rtt_state
            end

            def ping
                true
            end

            #Returns the property with the given name.
            #If no port can be found a exception is raised.
            def property(name, verify = true)
                name = name.to_str
                if @properties[name]
                    p = @properties[name]
                    p.tracked = true
                    p
                else
                    raise NotFound, "no property named '#{name}' on log task '#{self.name}'"
                end
            end

            #Returns the port with the given name.
            #If no port can be found a exception is raised.
            def port(name, verify = true)
                name = name.to_str
                if @ports[name]
                    @ports[name]
                elsif @invalid_ports[name]
                    raise NotFound, "the port named '#{name}' on log task '#{self.name}' could not be loaded: #{@invalid_ports[name]}"
                else
                    raise NotFound, "no port named '#{name}' on log task '#{self.name}'"
                end
            end

            #Adds a new property or port to the TaskContext
            #
            #* file_path = path of the log file
            #* stream = stream which shall be simulated as OutputPort
            def add_stream(file_path,stream)
                if Regexp.new(@file_path_config_reg).match(file_path) || stream.metadata["rock_stream_type"] == "property"
                    log = add_property(file_path,stream)
                else
                    log = add_port(file_path,stream)
                end
                log
            end

            #Adds a new property to the TaskContext
            #
            #* file_path = path of the log file
            #* stream = stream which shall be simulated as OutputPort
            def add_property(file_path,stream)
                if @file_path_config && !Regexp.new(@file_path_config).match(file_path)
                    raise "You are trying to add properties to the task from different log files #{@file_path}; #{file_path}!!!" if @file_path_config != file_path
                end
                if @file_path == file_path
                    @file_path = nil 
                end
                @file_path_config = file_path

                log_property = Property.new(self,stream)
                raise ArgumentError, "The log file #{file_path} is already loaded" if @properties.has_key?(log_property.name)
                @properties[log_property.name] = log_property
                @property_reachable_blocks.each{|b|b.call(log_property.name)}
                return log_property
            end

            #Adds a new port to the TaskContext
            #
            #* file_path = path of the log file
            #* stream = stream which shall be simulated as OutputPort
            def add_port(file_path,stream)
                #overwrite ports if the file is different and newer than the current one 
                if @file_path && @file_path != file_path
                    if File.new(@file_path).ctime < File.new(file_path ).ctime
                        Log.warn "For task #{name} using ports from \"#{file_path}\" instead of \"#{@file_path}\", because the file is more recent."
                        @ports.clear
                        @file_path = file_path
                    else
                        Log.warn "For task #{name} ommiting log file \"#{file_path}\", because it is older than \"#{@file_path}\"."
                        return nil
                    end
                else
                    @file_path = file_path
                end
                begin
                    log_port = OutputPort.new(self,stream)
                    raise ArgumentError, "The log file #{file_path} is already loaded" if @ports.has_key?(log_port.name)
                    @ports[log_port.name] = log_port
                    @port_reachable_blocks.each{|b|b.call(log_port.name)}
                rescue InitializePortError => error
                    @invalid_ports[error.port_name] = error.message
                    raise error
                end

                #connect state with task state
                if log_port.name == "state"
                    log_port.on_data do |sample|
                        @rtt_state = sample
                    end
                    log_port.tracked = false
                end
                log_port
            end

            #Returns an array of ports where each port has at least one connection
            #or tracked set to true.
            def used_ports
                @ports.values.find_all &:used?
            end

            #Returns an array of ports where each port has at least one connection
            #or tracked set to true.
            def used_properties
                @properties.values.find_all &:used?
            end

            #Returns true if the task shall be replayed
            def used?
                !used_ports.empty? || !used_properties.empty?
            end

            #Returns an array of unused ports
            def unused_ports
                ports = Array.new
                @ports.each_value do |port|
                    ports << port if !port.used?
                end
                return ports
            end

            def connect_to(task=nil,policy = OutputPort::default_policy,&block)
                Orocos::TaskContext.connect_to(self,task,policy,&block)
            end

            #If set to true all ports are replayed 
            #otherwise only ports are replayed which have a reader or
            #a connection to an other port
            def track(value,filter = Hash.new)
                options, filter = Kernel::filter_options(filter,[:ports,:types,:limit])
                raise "Cannot understand filter: #{filter}" unless filter.empty?

                @ports.each_value do |port|
                    if(options.has_key? :ports)
                        next unless port.name =~ options[:ports]
                    end
                    if(options.has_key? :types)
                        next unless port.type_name =~ options[:types]
                    end
                    if(options.has_key? :limit)
                        next unless port.number_of_samples <= options[:limit]
                    end
                    port.tracked = value
                    Log.info "set" + port.stream.name + value.to_s
                end

                @properties.each_value do |property|
                    if(options.has_key? :propertys)
                        next unless property.name =~ options[:properties]
                    end
                    if(options.has_key? :types)
                        next unless property.type_name =~ options[:types]
                    end
                    if(options.has_key? :limit)
                        next unless property.number_of_samples <= options[:limit]
                    end
                    property.tracked = value
                    @tracked = value
                    Log.info "set" + property.stream.name + value.to_s
                end
            end

            #Clears all reader buffers
            def clear_reader_buffers
                @ports.each_value do |port|
                    port.clear_reader_buffers
                end
            end

            def start(*args)
                raise "Task #{name} does not support this operation"
            end

            def configure(*args)
                raise "Task #{name} does not support this operation"
            end

            def stop(*args)
                raise "Task #{name} does not support this operation"
            end

            def cleanup(*args)
                raise "Task #{name} does not support this operation"
            end

            #This is used to allow the following syntax
            #task.port_name.connect_to(other_port)
            def method_missing(m, *args,&block) #:nodoc:
                m = m.to_s
                if m =~ /^(\w+)=/
                    name = $1
                    Log.warn "Setting the property #{name} the TaskContext #{@name} is not supported"
                    return
                end
                if has_port?(m) 
                    _port = port(m)
                    _port.filter = block if block         #overwirte filer
                    return _port
                end
                if has_property?(m) 
                    return property(m)
                end
                begin
                    super(m.to_sym,*args,&block)
                rescue  NoMethodError => e
                    if m.to_sym != :to_ary
                        Log.error "#{m} is neither a port nor a property of #{self.name}"
                        Log.error "The following ports are availabe:"
                        @ports.each_value do |port|
                            Log.error "  #{port.name}"
                        end
                        Log.error "The following properties are availabe:"
                        @properties.each_value do |property|
                            Log.error "  #{property.name}"
                        end
                    end
                    raise e
                end
            end
        end

    end
end

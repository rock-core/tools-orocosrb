require 'utilrb/logger'

module Orocos
    # Module for replaying log files
    module Log
	extend Logger::Hierarchy
	extend Logger::Forward

        #class which is storing stream annotions
        class Annotations
            attr_reader :samples
            attr_reader :stream
            attr_reader :file_name
            attr_reader :current_state

            def initialize(path,stream)
                @samples = Array.new
                @file_name = path
                @stream = stream
                @current_state = Hash.new

                stream.samples.each do |rt,lg,sample|
                    @samples << sample
                end

                @samples.sort! do |a,b|
                    a.time <=> b.time
                end
            end

            def write(sample)
                current_state[sample.key] = sample.value
            end

            def pretty_print(pp)
                pp.text "Stream name #{@file_name}, number of annotations #{@annotations.size}"
            end
        end

        # Class for loading and replaying pocolog (Rock) log files.
        #
        # This class creates objects whose API is compatible with
        # {Orocos::TaskContext} and {Orocos::OutputPort}, using the log data.
        #
        # By default, all tasks that are present in the log files provided to
        # {open} can be resolved using the orocos name service. If this
        # behaviour is unwanted, call {#deregister_tasks} after {.open} or {#load} was
        # called. To do it on a task-by-task basis, do the following after the
        # call to {.open} or {#load}
        #
        #     replay.name_service.deregister 'task_name'
        #
        class Replay
            include Namespace
            include Orocos::PortsSearchable

            class << self 
                attr_accessor :log_config_file 
            end
            @log_config_file = "properties."

            # @return [Orocos::Local] a local nameservice on which the log tasks
            #   are registered. It is added to the global name service with
            #   {#register_tasks} and removed with {#unregister_tasks}
	    attr_accessor :name_service

            # @return [Orocos::Async::Local] a local async nameservice on which the log tasks
            #   are registered. It is added to the global name service with
            #   {#register_tasks} and removed with {#unregister_tasks}
	    attr_accessor :name_service_async

            #desired replay speed = 1 --> record time
            attr_accessor :speed            

            #name of the log file which holds the logged properties
            #is converted into Regexp
            attr_accessor :log_config_file            

            #last replayed sample
            attr_reader :current_sample

            #array of all replayed ports  
            #this array is filled after {align} was called
            attr_accessor :replayed_ports

            #array of all replayed properties
            #this array is filled after {align} was called
            attr_accessor :replayed_properties

            #array of all replayed annotaions
            #this array is filled after {align} was called
            attr_accessor :replayed_annotations

            #set it to true if processing of qt events is needed during synced replay
            attr_accessor :process_qt_events

            # @return [Hash<String,#call>] a mapping from a typelib type name to
            #   an object that allows to extract the timestamp from a value of
            #   that type
            #
            # @see {timestamp}
            attr_reader :timestamps

            # Measure of time synchronization during replay
            #
            # This is updated during replay to reflect how fast the replay
            # actually is. This is the difference (in seconds) between the
            # replay time that we should have and the replay time that we
            # actually have
            #
            # In practice, negative values mean that the replayed samples are
            # behind the simulated times, and positive values mean that the
            # replayed samples are replayed to fast
            #
            # @return [Float]
            attr_reader :out_of_sync_delta

            # The actual replay speed 
            #
            # This is updated during replay, and reflects the actual replay
            # speed
            #
            # @return [Float]
            attr_reader :actual_speed

            #array of stream annotations
            attr_reader :annotations

            # The streams that are actually replayed
            #
            # @return [Array<Pocolog::DataStream>]
            attr_reader :used_streams

            # The current annotations
            #
            # This is an aggregated version of #annotations, where the value for
            # each key is the last value known (i.e. the value from the last
            # annotation with that key that has a timestamp lower than the
            # current time)
            def current_annotations
                annotations.inject(Hash.new) do |current, ann|
                    current.merge(ann.current_state)
                end
            end

            # Returns where from the time used for alignment should be taken. It
            # can be one of
            #
            # [false]
            #   use the time at which the logger received the data ("logical
            #   time")
            # [:use_sample_time]
            #   for streams whose data contains a field called "time" of type
            #   base/Time (from Rock's base/types package), use the time
            #   contained in that field. Otherwise, use the logical time.
            #
            # See #use_sample_time, #use_sample_time=
            def time_source
                if use_sample_time
                    return :use_sample_time
                else return false
                end
            end

            # If true, the alignment algorithm is going to use the sample time
            # for alignment. Otherwise, it uses the time at which the sample got
            # written on disk (logical time)
            #
            # See also #time_source
            attr_accessor :use_sample_time

            def self.open(*path)
                replay = new
                replay.load(*path)
                replay
            rescue ArgumentError => e
                Orocos.error "Cannot load logfiles"
                raise e 
            rescue Pocolog::Logfiles::MissingPrologue => e
                Orocos.error "Wrong log format"
                raise e
            end

            #Creates a new instance of Replay
            #
            #If a path is givien load is called after
            #creation to load the log files.
            def initialize(*path)
                if !path.empty?
                    raise ArgumentError, "Replay.new(*path) is deprecated, use Replay.open(*path) to create and load files at the same time"
                end

                @default_timestamp = nil
                @timestamps = Hash.new
                @tasks = Hash.new
                @annotations = Array.new
                @current_annotations = Hash.new
                @speed = 1
                @replayed_ports = Array.new
                @replayed_properties = Array.new
                @replayed_objects = Array.new
                @used_streams = Array.new
                @stream = nil
                @current_sample = nil
                @process_qt_events = false
                @log_config_file = Replay::log_config_file
                @namespace = ''
                reset_time_sync
                time_sync
            end

            #returns an array of all simulated tasks
            def tasks
                @tasks.values
            end

            #returns the time of the current sample replayed
            def time
                @base_time
            end

            #returns false if no ports are or will be replayed
            def replay? 
                #check if stream was initialized
                if @stream
                    return true
                else
                    each_task do |task|
                        return true if task.used?
                    end
                end
                return false
            end

            #pretty print for Replay
            def pretty_print(pp)
                pp.text "Orocos::Log::Replay"
                pp.nest(2) do
                    pp.breakable
                    pp.text "replay speed = #{@speed}"
                    pp.breakable
                    pp.text "Markers = #{@markers}"
                    pp.breakable
                    @tasks.each_value do |task|
                        pp.breakable
                        task.pretty_print(pp)
                    end
                    pp.breakable
                    pp.text "Stream Annotations:"
                    @annotations.each do |a|
                        pp.breakable
                        a.pretty_print(pp)
                    end
                end
            end

            def sample_index_for_time(time)
                prev_pos = sample_index
                seek(time)
                target_sample_pos = sample_index
                seek(prev_pos)
                return target_sample_pos
            end

            def sample_index()
                return @stream.sample_index if @stream
                return nil
            end

            def single_data(id)
                if @stream
                    return @stream.single_data(id)
                end
            end

            #Sets a code block to calculate the default timestamp duricng replay.
            def default_timestamp(&block)
                if block_given? then @default_timestamp = block
                else @default_timestamp
                end
            end

            # Declares how the timestamp can be extracted out of values of a given type
            #
            # @example use the 'time' field in /base/samples/RigidBodyState as timestamp
            #   replay.timestamp '/base/samples/RigidBodyState' do |rbs|
            #     rbs.time
            #   end
            #
            def timestamp(type_name, &block)
                timestamps[type_name] = block
            end

            #If set to true all ports are replayed and are not filtered out by the
            #filter
            #otherwise only ports are replayed which have a reader or
            #a connection to an other port
            def track(value,filter=Hash.new)
                options, filter = Kernel::filter_options(filter,[:tasks])
                @tasks.each_value do |task|
                    task.track(value,filter) if !options.has_key?(:tasks) || task.name =~ options[:tasks]
                end
            end

            #Tries to find a OutputPort for a specefic data type.
            #For port_name Regexp is allowed.
            #If precise is set to true an error will be raised if more
            #than one port is matching type_name and port_name.
            def port_for(type_name, port_name, precise=true)
                Log.warn "#port_for is deprecated. Use either #find_all_ports or #find_port"
                if precise
                    find_port(type_name, port_name)
                else find_all_ports(type_name, port_name)
                end
            end

            #Tries to connect all input ports of the OROCOS task to simulated OutputPorts
            #
            #==Parameter:
            # *task => task to connect to
            # *port_mappings => hash to define port mappings {src_port_name => dst_port_name}
            # *ports_ignored => array of port names which shall be ignored
            #
            def connect_to(task,port_mappings = Hash.new ,port_policies = Hash.new,ports_ignored = Array.new)
                #convenience block to do connect_to(task,:auto_ignore)
                if port_mappings == :auto_ignore
                    ports_ignored = port_mappings
                    port_mappings = Hash.new
                end
                ports_ignored = Array.new(ports_ignored)

                #start task if necessary 
                if task.state == :PRE_OPERATIONAL
                    task.configure
                end
                if task.state == :STOPPED
                    task.start
                end

                #to have a better user interface the hash is inverted 
                #port1 connect_to port2 is written as ('port1' => 'port2')
                port_mappings = port_mappings.invert

                task.each_port do |port|
                    if port.to_orocos_port.kind_of?(Orocos::InputPort) && !ports_ignored.include?(port.name)
                        target_port = find_port(port.type_name,port_mappings[port.name]||port.name)
                        if target_port
                            target_port.connect_to(port,port_policies[port.name])
                        elsif !ports_ignored.include? :auto_ignore
                            raise ArgumentError, "cannot find an output port for #{port.name}"
                        else
                            Log.warn "No input port can be found for output port #{port.full_name}."
                        end
                    end
                end
            end

            #Returns the simulated task with the given namen. 
            def task(name)
                name = map_to_namespace name
                raise "cannot find TaskContext which is called #{name}" if !@tasks.has_key?(name)
                return @tasks[name]
            end

            # Aligns all streams which have at least: 
            # * one reader 
            # * or one connections
            # * or track set to true.
            #
            # After calling this method no more ports can be tracked.
            #
            # time_source is passed through to the StreamAligner. It can be used
            # to override the global #time_source parameter. See #time_source
            # for available values.
            #
            def align( time_source = self.time_source )
                @replayed_ports = Array.new
                @used_streams = Array.new
                @replayed_annotations = Array.new

                if !replay?
                    Log.warn "No ports are selected. Assuming that all ports shall be replayed."
                    Log.warn "Connect port(s) or set their track flag to true to get rid of this message."
                    track(true)
                end

                #get all properties which shall be replayed
                each_task do |task|
                    if task.used?
                        task.port("state").tracked=true if task.has_port?("state")
                        task.properties.values.each do |property|
                            property.tracked = true
                            next if property.stream.empty?
                            @replayed_properties << property
                        end
                    end
                end

                #get all streams which shall be replayed
                each_port do |port|
                    if port.used?
                        next if port.stream.empty?
                        @replayed_ports << port
                    end
                end

                Log.info "Aligning streams --> all ports which are unused will not be loaded!!!"
                if @replayed_properties.empty? && @replayed_ports.empty?
                    raise "No log data are replayed. All selected streams are empty."
                end

                # If we do have something to replay, then add the annotations as
                # well
                annotations.each do |annotation|
                    next if annotation.stream.empty?
                    @replayed_annotations << annotation
                end

                @replayed_objects = @replayed_properties + @replayed_ports + @replayed_annotations
                @used_streams = @replayed_objects.map(&:stream)

                Log.info "Replayed Ports:"
                @replayed_ports.each {|port| Log.info PP.pp(port,"")}

                #join streams 
                @stream = Pocolog::StreamAligner.new(time_source, *@used_streams)
                @stream.rewind

                reset_time_sync
                return step
            end

            def advance
                if(@stream)
                    return @stream.advance
                else
                    throw "Stream is not initialized yet"
                end
            end

            def first_sample_pos(stream)
                @stream.first_sample_pos(stream)
            end

            def last_sample_pos(stream)
                @stream.last_sample_pos(stream)
            end

            # registers all replayed log tasks on the local name server
            def register_tasks
                @name_service ||= Local::NameService.new
                @name_service_async ||= Orocos::Async::Local::NameService.new :tasks => @tasks.values if defined?(Orocos::Async)
                @tasks.each_pair do |name,task|
                    @name_service.register task
                    @name_service_async.register task if @name_service_async
                end
                Orocos::name_service.add @name_service
                Orocos::Async.name_service.add @name_service_async if @name_service_async
            end

	    # deregister the local name service again
	    def deregister_tasks
		if @name_service 
		    Orocos::name_service.delete @name_service
		end
	    end

	    # close the log file, deregister from name service
	    # and also close all available streams 
	    def close
		deregister_tasks
		# TODO close all streams
	    end

            def stream_index_for_name(name)
                if @stream
                    return @stream.stream_index_for_name(name)
                end
                throw "Stream is not initialized yet"
            end

            def stream_index_for_type(name)
                if @stream
                    return @stream.stream_index_for_type(name)
                end
                throw "Stream is not initialized yet"
            end

            def aligned?
                return @stream != nil
            end

            # The total duration of the replayed data, in seconds
            #
            # @return [Float]
            def duration
                intervals = used_streams.map { |s| s.info.interval_lg }
                min = intervals.map(&:first).min
                max = intervals.map(&:last).max
                if min && max
                    max - min
                else 0
                end
            end

            #Resets the simulated time.
            #This should be called after the replay was paused.
            def reset_time_sync
                @start_time = nil 
                @base_time  = nil
                @actual_speed = 0
                @out_of_sync_delta = 0
            end

            #this can be used to set a different time sync logic
            #the code block has three parameters
            #time = current sample time
            #actual_delta = time between start of replay and now
            #required_delta = time which should have elapsed between start and now
            #to replay at the desired speed 
            #the code block must return the number of seconds which 
            #the replay shall wait before the sample is repalyed 
            #
            #Do not block the program otherwise qt events are no longer processed!!!
            #
            #Example
            #time_sync do |time,actual_delta,required_delta|
            #   my_object.busy? ? 1 : 0
            #end
            #
            def time_sync(&block)
                if block_given?
                    @time_sync_proc = block
                else
                    @time_sync_proc = Proc.new do |time,actual_delta,required_delta|
                        required_delta - actual_delta
                    end
                end
            end

            #returns ture if the next sample must be replayed to
            #meet synchronous replay
            def sync_step?
                calc_statistics
                if @out_of_sync_delta > 0.001
                    false
                else
                    true
                end
            end

            def current_time
                _, time, data = @current_sample
                return if !time
                if getter = (timestamps[data.class.name] || default_timestamp)
                    getter[data]
                else time
                end
            end

            def calc_statistics
                index, time, data = @current_sample
                if getter = (timestamps[data.class.name] || default_timestamp)
                    time = getter[data]
                end

                @base_time ||= time
                @start_time ||= Time.now

                required_delta = (time - @base_time)/@speed
                actual_delta   = Time.now - @start_time
                @out_of_sync_delta = @time_sync_proc.call(time,actual_delta,required_delta)
                @actual_speed = required_delta/actual_delta*@speed
            end

            # Gets the next sample, writes it to the ports which are connected
            # to the OutputPort and updates all its readers.
            #
            # If a block is given it is called this the name of the replayed port.
            #
            # @param [Boolean] time_sync if true, the method will sleep as much
            #   time as required to match the time delta in the file
            #
            # @yield [reader,sample]
            # @yieldparam reader the data reader of the port from which the
            #   sample has been read
            # @yieldparam sample the data sample
            #
            def step(time_sync=false,&block)
                #check if stream was generated otherwise call align
                if @stream == nil
                    return align
                end
                @current_sample = @stream.step
                return if !@current_sample
                index, time, data = @current_sample
                calc_statistics

                #wait if replay is faster than the desired speed and time_sync is set to true
                if time_sync &&  @out_of_sync_delta > 0.001
                    if @process_qt_events == true
                        start_wait = Time.now
                        while true
                            if $qApp
                                $qApp.processEvents()
                            end
                            break if !@start_time                           #break if start_time was reseted throuh processEvents
                            wait = @out_of_sync_delta -(Time.now - start_wait)
                            if wait > 0.001
                                sleep [0.01,wait].min
                            else
                                break
                            end
                            calc_statistics
                        end
                    else
                        sleep(@out_of_sync_delta)
                    end
                end

                #write sample to simulated ports or properties
                @replayed_objects[index].write(data)
                yield(@replayed_objects[index],data) if block_given?
                @current_sample
            end

            #Gets the previous sample and writes it to the ports which are connected
            #to the OutputPort and updated its readers (see step).
            def step_back(time_sync=false,&block)
                #check if stream was generated otherwise call start

                if @stream == nil
                    start
                    return
                end
                @current_sample = @stream.step_back
                return nil if @current_sample == nil
                index, time, data = @current_sample

                #write sample to connected ports
                @replayed_objects[index].write(data)
                yield(@replayed_objects[index],data) if block_given?
                return @current_sample
            end

            #Rewinds all streams and replays the first sample.
            def rewind()
                @stream.rewind
                step
            end

            #returns the last port which recieved data
            def current_port
                if @current_sample
                    index,_,_ = @current_sample
                    replayed_ports[index]
                end
            end

            #returns the current data of the current sample
            def current_sample_data
                if @current_sample
                    _,_,data = @current_sample
                    data
                end
            end

            # Extracts time intervals from the log file where the given
            # code block returns true.
            #
            # For each sample the given code block is called with the current
            # port and sample as parameter. After all samples were replayed the
            # generated result vector (true is interpreted as 1) is filtered
            # with a box filter of the given size. The returned intervals
            # are these intervals where the filtered result vector is equal
            # or bigger than min_val
            #
            # @param [Time] start_time Start time of the interval which is replayed (nil = start of the log file)
            # @param [Time] end_time End time of the interval which is replayed (nil = end of the log file)
            # @param [Float] min_val Min value of the filtered result vector to be regarded as inlayer
            # @param [Float] kernel_size Filter kernel size of the box filter in seconds
            # @yield [reader,sample]
            # @yieldparam reader the data reader of the port from which the
            #   sample has been read
            # @yieldparam sample the data sample
            # @yieldreturn [Boolean]
            #
            # @return [Array<Array<Time>>] extracted intervals
            def extract_intervals(start_time=nil,end_time=nil, min_val=0.8,kernel_size=5.0,&block)
                #replay given intervals and collect results of the code block
                result,times = [],[]
                start_time ||= begin
                              rewind
                              time
                          end
                seek(start_time)
                begin
                    if block.call(current_port,current_sample_data)
                        result << 1
                    else
                        result << 0
                    end
                    times << time
                end while(step && (!end_time || time <= end_time))

                #filter result vector
                idx,sum,size = 0,0,0
                filtered = result.map do |e|
                    while times[idx+size] - times[idx] < kernel_size && idx+size < times.size-1
                        size += 1
                        sum += result[idx+size]
                    end
                    val = if size > 0
                            sum/size
                          else
                              0
                          end
                    sum -= result[idx]
                    idx += 1
                    size -= 1
                    val
                end

                #extract intervals
                intervals,start = [],nil
                filtered.each_with_index do |e,i|
                    if e >= min_val
                        start ||= times[i]
                    elsif start
                        intervals << [start,times[i]] if times[i]-start >= kernel_size
                        start = nil
                    end
                end
                intervals
            end

            # Adds the given time intervals as LogMarkers
            #
            # @param [Array<Array<Time>>] intervals The intervals
            # @param [String] comment Comment of the log markers
            def add_intervals_as_log_markers(intervals,comment)
                markers = log_markers # fill @markers from log file
                intervals.each do |interval|
                    markers << LogMarker.new(interval.first,:start,-1,comment)
                    markers << LogMarker.new(interval.last,:stop,-1,comment)
                end
                markers.sort! do |a,b|
                    a.time <=> b.time 
                end
                markers
            end

            # Extracts time intervals from the log file where the given
            # code block returns true and adds these interval as log markers
            # to the log replay instance.
            #
            # @param [String] comment Comment of the log markers
            # @param [Float] min_val Min value of the filtered result vector to be regarded as inlayer
            # @param [Float] kernel_size Filter kernel size of the box filter in seconds
            # @yield [reader,sample]
            # @yieldparam reader the data reader of the port from which the
            #   sample has been read
            # @yieldparam sample the data sample
            # @yieldreturn [Boolean]
            #
            # @return [Array<Array<Time>>] extracted intervals
            # @see extract_intervals
            # @see add_intervals_as_log_markers
            def generate_log_markers(comment,min_val=0.8,kernel_size=5.0,&block)
                intervals = extract_intervals(nil,nil, min_val,kernel_size,&block)
                add_intervals_as_log_markers(intervals,comment)
                rewind
                intervals
            end

            #Runs through the log files until the end is reached.
            def run(time_sync = false,speed=1,&block)
                reset_time_sync
                @speed = speed
                while step(time_sync,&block) do
                end
            end

            #Iterates through all simulated ports.
            def each_port(&block)
                @tasks.each_value do |task|
                    task.each_port(&block)
                end
            end

            #Returns an array of all simulated ports 
            def ports
                result = Array.new
                each_port do |port|
                    result << port
                end
                result
            end

            #returns an array of log_markers
            def log_markers
                @markers ||= Array.new
                return @markers if !@markers.empty?

                annotations.each do |annotation|
                    #check if this is the right type
                    if annotation.stream.type_name == "/logger/Annotations"
                        @markers.concat LogMarker::parse(annotation.samples)
                    end
                end
                @markers.sort! do |a,b|
                    a.time <=> b.time 
                end
                @markers
            end

            def has_task?(name)
                name = map_to_namespace name
                @tasks.has_key?(name.to_s)
            end

            #Iterates through all simulated tasks
            def each_task (&block)
                @tasks.each_value do |task|
                    yield(task) if block_given?
                end
            end

            #Returns the current position of the replayed sample.
            def sample_index
                @stream.sample_index
            end

            #Returns the number of samples.
            def size
                return @stream.size
            end

            #Returns the time of the current sample.
            def time
                return @stream.time
            end

            #Returns true if the end of file is reached.
            def eof?
                return @stream.eof?
            end

            #Seeks to the given position
            def seek(pos)
                #check if stream was generated otherwise call align
                align if @stream == nil
                @current_sample = @stream.seek(pos)
                #write all data to the ports
                0.upto(@stream.streams.length-1) do |index|
                    data = @stream.single_data(index)
                    #only write samples if they are available
                    if(data)
                        @replayed_objects[index].write(data)
                    end
                end
            end

            #replays the last sample to the log port
            def refresh
                index, time, data = @current_sample
                @replayed_objects[index].write(data)
            end

            def load_task_from_stream(stream,path)
                #get the name of the task which was logged into the stream
                task_name = if stream.metadata.has_key? "rock_task_name"
                                begin
                                    namespace, _ = Namespace.split_name(stream.metadata["rock_task_name"])
                                    Namespace.validate_namespace_name(namespace)
                                rescue ArgumentError => e
                                    Orocos.warn "invalid metadata rock_task_name:'#{stream.metadata["rock_task_name"]}' for stream #{stream.name}: #{e}"
                                    stream.metadata.delete("rock_task_name")
                                    return load_task_from_stream(stream,path)
                                end
                                stream.metadata["rock_task_name"]
                            else
                                result = stream.name.to_s.match(/^(.*)\./)
                                result[1] if result
                            end
                if task_name == nil
                    task_name = "unknown"
                    Log.warn "Stream name (#{stream.name}) does not follow the convention TASKNAME.PORTNAME and has no metadata, assuming as TASKNAME \"#{task_name}\""
                end

                #check if there is a namespace
                task_name = if task_name == basename(task_name)
                                map_to_namespace(task_name)
                            else
                                task_name
                            end

                task = @tasks[task_name]
                if !task
                    task = @tasks[task_name]= TaskContext.new(self,task_name, path,@log_config_file)
                end

                begin
                    task.add_stream(path,stream)
                    Log.info "    loading stream #{stream.name} (#{stream.type_name})"
                rescue InitializePortError => error
                    Log.warn "    loading stream #{stream.name} (#{stream.type_name}) failed. Call the port for an error message."
                end
                task
            end

            # Loads all the streams defined in the provided log file
            def load_log_file(file, path)
                Log.info "  loading log file #{path}"
                file.streams.each do |s|
                    if s.metadata["rock_stream_type"] == "annotations"
                        @annotations << Annotations.new(path,s)
                        next
                    end
                    load_task_from_stream(s,path)
                end
            end

            #Loads a log files and creates TaskContexts which simulates the recorded tasks.
            #You can either specify a single file or a hole directory. If you want to load
            #more than one directory or file simultaneously you can use an array.
	    #
	    #Logs that share the same basename, will be joined such that the streams within
	    #the logs appear continous.
	    #
	    #a collection of files/directories can be given as arguments, followed by a 
	    #typelib registry and/or an options hash. The options can be given as:
	    #
	    # :registry - same as providing the registry directly
	    # :multifile - set to :last if you don't want merging of logs with the same
	    #              basename
	    #
            def load(*paths)
                paths.flatten!
                raise ArgumentError, "No log file was given" if paths.empty?

                logreg = nil
                if paths.last.kind_of?(Typelib::Registry)
                    logreg = paths.pop
                end
		opts = {}
		if paths.last.kind_of?(Hash)
		    opts = paths.pop
		    logreg = opts[:registry] if opts[:registry]
		end

                paths.each do |path| 
                    #check if path is a directory
                    path = File.expand_path(path)
                    if File.directory?(path)
                        all_files = Dir.enum_for(:glob, File.join(path, '*.*.log'))
                        by_basename = all_files.inject(Hash.new) do |h, path|
                            split = path.match(/^(.*)\.(\d+)\.log$/)
                            if split
                                basename, number = split[1], Integer(split[2])
                                h[basename] ||= Array.new
                                h[basename][number] = path
                                h
                            else
                                Orocos.warn "invalid log file name #{path}. Expecting: /^(.*)\.(\d+)\.log$/"
                                h
                            end
                        end
                        if by_basename.empty?
                            Orocos.warn "empty directory: #{path}"
                            next
                        end

                        by_basename.each_value do |files|
			    if opts[:multifile] == :last 
				files = files[-1,1]
			    end
			    args = files.compact.map do |path|
				File.open(path)
			    end

                            args << logreg

                            logfile = Pocolog::Logfiles.new(*args.compact)
                            load_log_file(logfile, files.first)
                        end
                    elsif File.file?(path)
                        file = Pocolog::Logfiles.open(path, logreg)
                        load_log_file(file, path)
                    else
                        raise ArgumentError, "Can not load log file: #{path} is neither a directory nor a file"
                    end
                end
                raise ArgumentError, "Nothing was loaded from the following log files #{paths.join("; ")}" if @tasks.empty?

                #register task on the local name server
                register_tasks
            end

            # Clears all reader buffers.
            # This is usefull if you are changing the replay direction.
            def clear_reader_buffers
                @tasks.each_value do |task|
                    task.clear_reader_buffers
                end
            end

            # exports all aligned stream to a new log file 
            # if no start and end index is given all data are exported
            # otherwise the data are truncated according to the given global indexes 
            # the block is called for each sample to update a progress bar 
            def export_to_file(file,start_index=0,end_index=0,&block)
                @stream.export_to_file(file,start_index,end_index,&block)
            end

            #This is used to support the syntax.
            #log_replay.task 
            def method_missing(m,*args,&block) #:nodoc:
                task = @tasks[map_to_namespace(m.to_s)]
                return task if task

                begin  
                    super(m.to_sym,*args,&block)
                rescue  NoMethodError => e
                    Log.error "#{m} is not a Log::Task of the current log file(s)"
                    Log.error "The following tasks are availabe:"
                    @tasks.each_value do |task|
                        Log.error "  #{task.name}"
                    end
                    raise e 
                end
            end
        end
    end
end


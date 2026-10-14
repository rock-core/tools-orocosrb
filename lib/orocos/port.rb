require 'utilrb/kernel/options'
require 'utilrb/module/attr_predicate'

module Orocos
    class << self
	# Setup of the logger will try to determine the timestamp field in a
	# datatype. For this it uses the first field in the type, which is of type
	# base/Time. If set to false (default), Time::now is used for the log time
	# of each log sample.
	attr_predicate :logger_guess_timestamp_field?, true
    end

    self.logger_guess_timestamp_field = false

    # Base class for port classes.
    #
    # See OutputPort and InputPort
    class Port
        include PortBase

	class << self
	    # The only way to create a Port object (and its derivatives) is
	    # TaskContext#port
	    private :new
	end

        @@transient_port_id_counter = 0
        def self.transient_local_port_name(base_name)
            "#{base_name}.#{@@transient_port_id_counter += 1}"
        end

        @transport_names = Hash.new
        class << self
            # A mapping from a transport ID to its name in plain text
            attr_reader :transport_names
        end

        # Returns the transport name for the given transport ID or a placeholder
        # sentence if no name is known for this transport ID
        def self.transport_name(id)
            transport_names[id] || "unknown transport with ID #{id}"
        end

        # @deprecated
        # Returns the name of the typelib type. Use #type.name instead.
        def type_name; type.name end

        def pretty_print(pp) # :nodoc:
            if type.name != orocos_type_name
                pp.text " #{name} (#{type.name}/#{orocos_type_name})"
            else
                pp.text " #{name} (#{type.name})"
            end
        end

        # Removes this port from all connections it is part of
        def disconnect_all
            refine_exceptions do
                do_disconnect_all
            end
        end

        DEFAULT_CONNECTION_POLICY = {
            type: :data,
            init: false,
            pull: false,
            data_size: 0,
            size: 0,
            lock: :lock_free,
            transport: 0,
            name_id: "",
            signalling: true
        }.freeze
        CONNECTION_POLICY_OPTIONS = DEFAULT_CONNECTION_POLICY.keys

        # A connection policy is represented by a hash whose elements are each
        # of the policy parameters. Valid policies are:
        #
        # * buffer policy. Values are stored in a FIFO of the specified size.
        #   Connecting with a buffer policy is done with:
        #
        #      output_port.connect_to(input_port, :type => :buffer, :size => 10)
        #
        # * data policy. The input port will always read the last value pushed by the
        #   output port. It is the default policy, but can be explicitly specified with:
        #
        #      output_port.connect_to(input_port, :type => :data)
        #
        # An additional +:pull+ option specifies if samples should be pushed by the
        # output end (i.e. if all samples that are written on the output port are sent to
        # the input port), or if the values are transmitted only when the input port is
        # read. For instance:
        #
        #   output_port.connect_to(input_port, :type => :data, :pull => true)
        #
        # Finally, the type of locking can be specified. The +lock_free+ locking
        # policy guarantees that a high-priority thread will not be "taken over"
        # by a low-priority one, but requires a lot of copying -- so avoid it in
        # non-hard-realtime contexts with big data samples. The +locked+ locking
        # policy uses mutexes, so is not ideal in hard realtime contexts. Each
        # policy is specified with:
        #
        #   output_port.connect_to(input_port, :lock => :lock_free)
        #   output_port.connect_to(input_port, :lock => :locked)
        #
        # This method raises ArgumentError if the policy is not valid.
        def self.validate_policy(policy)
            policy = validate_options policy, CONNECTION_POLICY_OPTIONS
            if policy.has_key?(:type)
                policy[:type] = policy[:type].to_sym
            end
            if policy.has_key?(:lock)
                policy[:lock] = policy[:lock].to_sym
            end

            if (policy[:type] == :buffer || policy[:type] == :circular_buffer) && !policy[:size]
                raise ArgumentError, "you must provide a 'size' argument for buffer connections"
            elsif policy[:type] == :data && (policy[:size] && policy[:size] != 0)
                raise ArgumentError, "there are no 'size' argument to data connections"
            end
            policy
        end

        # fills missing policy fields with default values, checks
        # if the generated policy is valid and returns it
        def self.prepare_policy(policy = Hash.new)
            policy = DEFAULT_CONNECTION_POLICY.merge policy
            Port.validate_policy(policy)
        end

        # Returns true if a documentation about the port is available
        # otherwise it retuns false
        def doc?
            (doc && !doc.empty?)
        end

        # Returns a documentation string describing the port
        # If no documentation is available it returns nil
        def doc
            if model
                model.doc
            end
        end

        #Returns the Orocos port
        def to_orocos_port
            self
        end

        # Publishes or subscribes this port on a stream
        def create_stream(transport, name_id, policy = Hash.new)
            policy = Port.prepare_policy(policy)
            policy[:transport] = transport
            policy[:name_id] = name_id
            do_create_stream(policy)

            self
        rescue Orocos::ConnectionFailed => e
            raise e, "failed to create stream from #{full_name} on transport #{Port.transport_name(transport)}, name #{name_id} and policy #{policy.inspect}"
        end

        # Removes a stream publication. The name should be the same than the one
        # given to the
        def remove_stream(name_id)
            do_remove_stream(name_id)
            self
        end

        def refine_exceptions(other = nil) # :nodoc:
            CORBA.refine_exceptions(self, other) do
                yield
            end

        rescue NotFound
            if !other || task.has_port?(name)
                raise InterfaceObjectNotFound.new(task, name), "port '#{name}' disappeared from task '#{task.name}'"
            else
                raise InterfaceObjectNotFound.new(other.task, other.name), "port '#{other.name}' disappeared from task '#{other.task.name}'"
            end
        end

        class InvalidMQTransportSetup < ArgumentError; end

        MQ_RTT_DEFAULT_QUEUE_LENGTH = 10

        # Helper method for #connect_to, to handle the MQ transport (in
        # particular, the validation of the parameters)
        #
        # A block must be given, that should return true if the MQ transport
        # should be used for this particular connection and false otherwise
        # (i.e. true if the two ports are located on the same machine, false
        # otherwise)
        def handle_mq_transport(input_name, policy) # :nodoc:
            if policy[:transport] == TRANSPORT_MQ
                if !Orocos::MQueue.available?
                    raise InvalidMQTransportSetup, "cannot select the MQueue transport as it is not built into the RTT"
                end
                # Go on to the validation steps
            elsif !Orocos::MQueue.available?
                return policy.dup
            elsif !Orocos::MQueue.auto?
                return policy.dup
            elsif policy[:transport] != 0
                return policy.dup # explicit transport chosen, and it is not MQ
            end

            Orocos.info do
                "#{full_name} => #{input_name}: using MQ transport"
            end
            updated_policy = Hash[size: 0, data_size: 0].
                merge(policy).
                merge(transport: TRANSPORT_MQ)

            queue_length, message_size = updated_policy.values_at(:size, :data_size)
            if queue_length == 0
                queue_length = MQ_RTT_DEFAULT_QUEUE_LENGTH
            end

            if Orocos::MQueue.auto_sizes? && message_size == 0
                size = max_marshalling_size
                if !size
                    if policy[:transport] == TRANSPORT_MQ
                        raise InvalidMQTransportSetup, "MQ transport explicitely selected, but the message size cannot be computed for #{self}"
                    end

                    if Orocos::MQueue.warn?
                        Orocos.warn "the MQ transport could be selected, but the marshalling size of samples from the output port #{full_name}, of type #{type.name}, is unknown, falling back to auto-transport"
                    end
                    return policy.dup
                end

                Orocos.info do
                    "#{full_name} => #{input_name}: MQ data_size == #{size}"
                end
                message_size = size
            end

            if Orocos::MQueue.validate_sizes?
                valid = Orocos::MQueue.valid_sizes?(queue_length, message_size) do
                    "#{full_name} => #{input_name} of type #{type.name}: "
                end

                if !valid
                    if policy[:transport] == TRANSPORT_MQ
                        raise InvalidMQTransportSetup, "MQ transport explicitely selected, but the current system setup does not allow to create a MQ of #{queue_length} messages of size #{message_size}"
                    end

                    if Orocos::MQueue.warn?
                        Orocos.warn "the MQ transport could be selected, but the marshalling size of samples (#{policy[:data_size]}) is invalid, falling back to auto-transport"
                    end
                    return policy.dup
                end
            end

            updated_policy[:data_size] = message_size
            updated_policy
        end
    end
end


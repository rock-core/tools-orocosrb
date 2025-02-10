module Orocos
    # This class represents output ports on remote task contexts.
    #
    # They are obtained from TaskContext#port or TaskContext#each_port
    class OutputPort < Port
        include OutputPortBase

        def pretty_print(pp) # :nodoc:
            pp.text "out "
            super
        end

        # Used by OutputPortReadAccess to determine which output reader class
        # should be used
        def self.reader_class; OutputReader end

        # Connect this output port to an input port. +options+ defines the
        # connection policy for the connection. If a task is given instead of
        # an input port the method will try to find the right input port
        # by type and will raise an error if there are
        # none or more than one matching input ports
        #
        # The following options are available:
        #
        # Data connections. In that connection, the reader will see only the
        # last sample he received. Such a connection is set up with
        #
        #   input_port.connect_to output_port, :type => :data
        #
        # Buffered connections. In that case, the reader will be able to read
        # all the samples received since the last read. A buffer in between the
        # output and input port will keep the samples that have not been read
        # already.  Such a connection is set up with:
        #
        #   output_port.connect_to input_port, :type => :buffer, :size => 10
        #
        # Where the +size+ option gives the size of the intermediate buffer.
        # Note that new samples will be lost if they are received when the
        # buffer is full.
        def connect_to(input_port, distance: D_UNKNOWN, **options)
            if !input_port.respond_to?(:to_orocos_port)
                return super
            end

            input_port = input_port.to_orocos_port
            if !input_port.kind_of?(InputPort)
                raise ArgumentError, "an output port can only connect to an input port (got #{input_port})"
            elsif input_port.type.name != type.name
                raise ArgumentError, "trying to connect #{self}, an output port of type #{type.name}, to #{input_port}, an input port of type #{input_port.type.name}"
            end

            policy = Port.prepare_policy(**options)
            if distance == D_UNKNOWN
                distance = distance_to(input_port)
            end
            if distance == D_SAME_HOST
                policy = handle_mq_transport(input_port.full_name, policy)
            end
            if policy[:pull]
                input_port.blocking_read = true
            end

            begin
                refine_exceptions(input_port) do
                    do_connect_to(input_port, policy)
                end
            rescue Orocos::ConnectionFailed => e
                if policy[:transport] == TRANSPORT_MQ && Orocos::MQueue.auto_fallback_to_corba?
                    policy[:transport] = TRANSPORT_CORBA
                    Orocos.warn "failed to create a connection from #{full_name} to #{input_port.full_name} using the MQ transport, falling back to CORBA"
                    retry
                end
                raise
            end

            self
        rescue Orocos::ConnectionFailed => e
            raise e, "failed to connect #{full_name} => #{input_port.full_name} with policy #{policy.inspect}"
        end

        # Require this port to disconnect from the provided input port
        def disconnect_from(input)
            if !input.respond_to?(:to_orocos_port)
                return super
            end

            input = input.to_orocos_port
            refine_exceptions(input) do
                do_disconnect_from(input)
            end
        end

        # Create the half-channel that can transfer data from this port
        #
        # The channel is not connected to the port (yet). The general connection
        # process is (order matters !)
        #
        #     output_port_channel, policy = output.build_channel_half(insert your policy)
        #     input_port_channel = input.build_channel_half(**policy)
        #     output_port_channel.remote_side = input_port_channel
        #     input_port_channel.remote_side = output_port_channel
        #     output_port.connect_channel_half(output_port_channel, init: true)
        #     input_port.connect_channel_half(input_port_channel)
        #
        # @param [Hash] policy the connection policy
        # @return [(ChannelElement,Hash)] the created channel and the updated connection
        #   policy. The returned policy must be the one given to the
        #   {InputPort#build_channel_half} method
        def build_channel_half(**policy)
            policy = Port.prepare_policy(**policy)
            remote_build_channel_half(policy)
        end

        # Connect a channel to this port
        #
        # The general connection process is (order matters !)
        #
        #     output_port_channel, policy = output.build_channel_half(insert your policy)
        #     input_port_channel = input.build_channel_half(**policy)
        #     output_port_channel.remote_side = input_port_channel
        #     input_port_channel.remote_side = output_port_channel
        #     output_port.connect_channel_half(output_port_channel, init: true)
        #     input_port.connect_channel_half(input_port_channel)
        #
        # @param [Hash] policy the connection policy as returned by
        #   {OutputPort#build_channel_half}
        def connect_channel_half(channel, policy)
            remote_connect_channel_half(channel, policy)
        end
    end
end

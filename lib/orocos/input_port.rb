module Orocos
    # This class represents output ports on remote task contexts.
    #
    # They are obtained from TaskContext#port or TaskContext#each_port
    class InputPort < Port
        include InputPortBase

        # Whether a {#read} should be considered blocking
        #
        # This is set as soon as at least one connection involving this port is
        # set with the 'pull' option
        attr_predicate :blocking_read?, true

        def initialize(task, name, orocos_type_name, model)
            super
            @blocking_read = false
        end

        # Used by InputPortWriteAccess to determine which class should be used
        # to create the writer
        def self.writer_class
            InputWriter
        end

        def pretty_print(pp) # :nodoc:
            pp.text "in "
            super
        end

        # Create the half-channel that can receive data for this port
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
        # @param [Hash] policy the connection policy as returned by
        #   {OutputPort#build_channel_half}
        # @return [ChannelElement] the created channel
        def build_channel_half(policy)
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

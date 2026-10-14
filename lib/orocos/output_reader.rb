module Orocos
    # Local input port that is specifically designed to read to another task's output port
    class OutputReader < RubyTasks::LocalInputPort
        # The port this object is reading from
        attr_accessor :port

        # The policy of the connection
        attr_accessor :policy

        # Helper method for #read and #read_new
        #
        # This is overloaded in OutputReader to raise CORBA::ComError if the
        # process supporting the remote task is known to be dead
        def raw_read_with_result(sample, copy_old_data)
            if (process = port.task.process)
                disconnect_all unless process.alive?
            end

            super
        end

        # Reads a sample on the associated output port. Returns a value as soon
        # as a sample has ever been written to the port since the data reader
        # has been created
        #
        # @raise [CORBA::ComError] if the remote process is known to be dead.
        # This is only possible if the remote deployment has been started by
        # this Ruby instance
        def read(sample = nil)
            if !policy[:pull]
                Orocos.allow_blocking_calls do
                    # Non-pull readers are non-blocking
                    super
                end
            else
                super
            end
        end

        # Reads a sample on the associated output port, and returns nil if no
        # new data is available
        #
        # @raise [CORBA::ComError] if the remote process is known to be dead.
        # This is only possible if the remote deployment has been started by
        # this Ruby instance
        # @see read
        def read_new(sample = nil)
            if !policy[:pull]
                Orocos.allow_blocking_calls do
                    # Non-pull readers are non-blocking
                    super
                end
            else
                super
            end
        end

        # Disconnects this port from the port it is reading
        def disconnect
            disconnect_all
        end
    end
end


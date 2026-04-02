module Orocos
    # Local output port that is specifically designed to write to another task's input port
    class InputWriter < RubyTasks::LocalOutputPort
        # The port this object is reading from
        attr_accessor :port

        # The policy of the connection
        attr_accessor :policy

        # Disconnects this port from the port it is reading
        def disconnect
            disconnect_all
        end

        # Write data on the associated input port
        #
        # @raise [CORBA::ComError] if the remote process is known to be dead.
        #   This is only possible if the remote deployment has been started by
        #   this Ruby instance. Set raise_on_disconnection to false to disable
        def write(
            data,
            raise_on_disconnection: Orocos.input_writer_write_raises_on_disconnection?
        )
            return super(data) unless raise_on_disconnection

            if process = port.task.process
                if !process.alive?
                    disconnect_all
                    raise CORBA::ComError, "remote end is dead"
                end
            end

            if !super(data)
                raise CORBA::ComError, "remote end was disconnected"
            else true
            end
        end
    end
end


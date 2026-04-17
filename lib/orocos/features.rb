module Orocos
    class << self
        # Controls whether InputWriter#write should raise if it detects
        # it has been disconnected.
        #
        # This is true for historical reasons, to make ruby scripts more
        # robust. More advanced tooling should set to false.
        attr_writer :input_writer_write_raises_on_disconnection

        # Controls whether InputWriter#write should raise if it detects
        # it has been disconnected.
        #
        # This is true for historical reasons, to make ruby scripts more
        # robust. More advanced tooling should set to false.
        def input_writer_write_raises_on_disconnection?
            @input_writer_write_raises_on_disconnection
        end
    end

    @input_writer_write_raises_on_disconnection = true
end
require 'rorocos_ext'
require 'typelib'

module Orocos
    Port.transport_names[TRANSPORT_CORBA] = 'CORBA'

    module CORBA
        extend Logger::Forward
        extend Logger::Hierarchy

        class << self
            # The maximum message size, in bytes, allowed by the omniORB. It can
            # only be set before Orocos.initialize is called
            #
            # Orocos.rb sets it to 4MB by default
            attr_reader :max_message_size

            def max_message_size=(value)
                if initialized?
                    raise "the maximum message size can only be changed before the CORBA layer is initialized"
                end

                ENV['ORBgiopMaxMsgSize'] = value.to_int.to_s
            end
        end

        class << self
            # Returns the current timeout for method calls, in milliseconds
            # Orocos.rb sets it to 20000 ms by default
            #
            # See #call_timeout= for a complete description
            attr_reader :call_timeout

            # Sets the timeout, in milliseconds, for a CORBA method call to be
            # completed. It means that no method call can exceed the specified
            # value.
            def call_timeout=(value)
                do_call_timeout(value)
                @call_timeout = value
            end

            # Returns the timeout, in milliseconds, before a connection creation
            # fails.
            # Orocos.rb sets it to 2000 ms by default
            #
            # See #connect_timeout=
            attr_reader :connect_timeout

            # Sets the timeout, in milliseconds, before a connection creation
            # fails.
            def connect_timeout=(value)
                do_connect_timeout(value)
                @connect_timeout = value
            end
        end

        # For backward compatibility reasons. Use Orocos.load_typekit instead
        def self.load_typekit(name)
            Orocos.load_typekit(name)
        end

        # Initialize the CORBA layer
        # 
        # It does not need to be called explicitely, as it is called by
        # Orocos.initialize
	def self.init(name = nil)
            #setup environment which is used by the orocos.rb
	    if CORBA.name_service.ip
	        ENV['ORBInitRef'] = "NameService=corbaname::#{CORBA.name_service.ip}"
	    end

            do_init(name || "")
            self.call_timeout    ||= 20000
            self.connect_timeout ||= 2000

            #check if name service is reachable
            CORBA.name_service.validate
	end

	def self.get(method, name)
            if !Orocos::CORBA.initialized?
                raise NotInitialized, "the CORBA layer is not initialized, call Orocos.initialize first"
            end

            result = ::Orocos::CORBA.refine_exceptions("naming service") do
                ::Orocos::TaskContext.send(method, name)
            end
	    result
	end

        # Deinitializes the CORBA layer
        #
        # It shuts down the CORBA access and deregisters the Ruby process from
        # the server
        def self.deinit
            do_deinit
        end

        # Improves exception messages for exceptions that are raised from the
        # C++ extension
        def self.refine_exceptions(obj0, obj1 = nil) # :nodoc:
            yield

        rescue ComError => e
            if !obj1
                raise ComError, "communication failed with #{obj0}", e.backtrace
            else
                raise ComError, "communication failed with either #{obj0} or #{obj1}", e.backtrace
            end
        end
    end

end


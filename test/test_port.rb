require 'orocos/test'

describe Orocos::Port do
    include Orocos::Spec

    it "should not be possible to create an instance directly" do
	assert_raises(NoMethodError) { Orocos::Port.new }
    end

    it "should check equality based on CORBA reference" do
        task = new_ruby_task_context 'task'
        task.create_output_port 'out', '/double'
        task = Orocos.get 'task'
        p1 = task.port 'out'
        # Remove p1 from source's port cache
        task.instance_variable_get("@ports").delete("out")
        p2 = task.port 'out'
        refute_same(p1, p2)
        assert_equal(p1, p2)
    end

    describe ".validate_policy" do
        it "should raise if a buffer is given without a size" do
            assert_raises(ArgumentError) { Orocos::Port.validate_policy :type => :buffer }
        end
        it "should raise if a data is given with a size" do
            assert_raises(ArgumentError) { Orocos::Port.validate_policy :type => :data, :size => 10 }
        end
    end

    describe ".default_buffer_type" do
        after do
            Orocos::Port.default_buffer_type = :fifo_buffer
        end

        it "is initialized to fifo_buffer" do
            assert_equal :fifo_buffer, Orocos::Port.default_buffer_type
        end

        it "can be changed to circular_buffer" do
            Orocos::Port.default_buffer_type = :circular_buffer
            assert_equal :circular_buffer, Orocos::Port.default_buffer_type
        end

        it "can be changed back to fifo_buffer" do
            Orocos::Port.default_buffer_type = :circular_buffer
            Orocos::Port.default_buffer_type = :fifo_buffer
            assert_equal :fifo_buffer, Orocos::Port.default_buffer_type
        end
    end

    describe "the 'buffer' connection type in connection policies" do
        before do
            @source_task = new_ruby_task_context("source")
            @source_task.create_output_port "p", "/int32_t"
            @sink_task = new_ruby_task_context("sink")
            @sink_task.create_input_port "p", "/int32_t"
        end

        after do
            Orocos::Port.default_buffer_type = :fifo_buffer
        end

        it "uses fifo_buffer by default" do
            @source_task.p.connect_to @sink_task.p, type: :buffer, size: 2
            @source_task.p.write 1
            @source_task.p.write 2
            @source_task.p.write 3

            assert_equal 1, @sink_task.p.read_new
            assert_equal 2, @sink_task.p.read_new
            assert_nil @sink_task.p.read_new
        end

        it "uses circular_buffer if default_buffer_type has been changed" do
            Orocos::Port.default_buffer_type = :circular_buffer
            @source_task.p.connect_to @sink_task.p, type: :buffer, size: 2
            @source_task.p.write 1
            @source_task.p.write 2
            @source_task.p.write 3

            assert_equal 2, @sink_task.p.read_new
            assert_equal 3, @sink_task.p.read_new
            assert_nil @sink_task.p.read_new
        end
    end

    it "supports CORBA connection creation via #connect_to" do
        out_task = new_ruby_task_context "out_task"
        out_task.create_output_port "out", "/double"
        out_task_corba = Orocos::TaskContext.new out_task.ior
        in_task = new_ruby_task_context "in_task"
        in_task.create_input_port "in", "/double"
        in_task_corba = Orocos::TaskContext.new in_task.ior

        out_task_corba.out.connect_to in_task_corba.in
        out_task.out.write 10
        assert_equal 10, in_task.in.read_new
    end

    describe "the explicit connection creation method" do
        attr_reader :in_task, :out_task, :in_task_corba, :out_task_corba

        before do
            @out_task = new_ruby_task_context "out_task"
            @out_task_corba = Orocos::TaskContext.new out_task.ior
            @in_task = new_ruby_task_context "in_task"
            @in_task_corba = Orocos::TaskContext.new in_task.ior
            @channels = []
        end

        after do
            @channels.each(&:disconnect_half)
        end

        it "creates plain corba connections" do
            out_task.create_output_port "out", "/double"
            in_task.create_input_port "in", "/double"
            out_port_channel, policy = out_task_corba.out.build_channel_half
            in_port_channel = in_task_corba.in.build_channel_half(policy)
            @channels << out_port_channel << in_port_channel
            out_port_channel.remote_side = in_port_channel
            in_port_channel.remote_side = out_port_channel
            out_task_corba.out.connect_channel_half(out_port_channel, policy)
            in_task_corba.in.connect_channel_half(in_port_channel, policy)

            out_task.out.write 10
            assert_eventually_equals(10) { in_task.in.read_new }
        end

        it "supports the 'init' mechanism" do
            in_task.create_input_port "in", "/int"
            out_port_channel, policy =
                out_task_corba.port("state").build_channel_half(init: true)
            in_port_channel = in_task_corba.in.build_channel_half(policy)
            @channels << out_port_channel << in_port_channel

            out_port_channel.remote_side = in_port_channel
            in_port_channel.remote_side = out_port_channel
            out_task_corba
                .port("state")
                .connect_channel_half(out_port_channel, policy)
            in_task_corba.in.connect_channel_half(in_port_channel, policy)

            assert_eventually_equals(1) { in_task.in.read_new }
        end

        it "handles being disposed with half channels" do
            out_task.create_output_port "out", "/double"
            in_task.create_input_port "in", "/double"
            _, policy = out_task_corba.port("state").build_channel_half(init: true)
            in_task_corba.in.build_channel_half(policy)
            out_task.dispose
            in_task.dispose
        end

        it "sets up MQ links" do
            out_task.create_output_port "out", "/double"
            in_task.create_input_port "in", "/double"

            policy = { transport: Orocos::TRANSPORT_MQ, data_size: 8 }
            out_port_channel, policy = out_task_corba.out.build_channel_half(**policy)
            in_port_channel, = in_task_corba.in.build_channel_half(policy)
            @channels << out_port_channel << in_port_channel
            out_port_channel.remote_side = in_port_channel
            in_port_channel.remote_side = out_port_channel
            out_task_corba.out.connect_channel_half(out_port_channel, policy)
            in_task_corba.in.connect_channel_half(in_port_channel, policy)

            out_task.out.write 10
            assert_eventually_equals(10) { in_task.in.read_new }
        end

        def assert_eventually_equals(expected, timeout: 5, poll: 0.05)
            deadline = Time.now + timeout
            values = []
            while Time.now <= deadline
                last_value = yield
                if expected == last_value
                    assert(true) # account for the assertion
                    return
                end

                values << last_value
                sleep poll
            end

            flunk(
                "block did not return the expected value #{expected}. " \
                "Received values: #{values}"
            )
        end
    end

    describe "handle_mq_transport" do
        attr_reader :port
        before do
            @port = new_ruby_task_context 'task' do
                output_port 'out', '/double'
            end.out
            Orocos::MQueue.auto = true
        end
        after do
            Orocos::MQueue.auto = false
        end

        it "creates an updated policy" do
            policy = Hash.new
            refute_same policy, port.handle_mq_transport("input", policy)
        end
        it "does nothing if MQueue.auto is false" do
            Orocos::MQueue.auto = false
            policy = Hash[transport: 0]
            updated_policy = port.handle_mq_transport("input", policy)
            assert_equal policy, updated_policy
        end
        it "raises if the transport is explicitely but the MQueues are not available" do
            flexmock(Orocos::MQueue).should_receive(:available?).and_return(false)
            assert_raises(Orocos::Port::InvalidMQTransportSetup) do
                port.handle_mq_transport("input", transport: Orocos::TRANSPORT_MQ)
            end
        end
        it "does nothing if the transport is neither zero nor TRANSPORT_MQ" do
            policy = Hash[transport: Orocos::TRANSPORT_CORBA]
            updated_policy = port.handle_mq_transport("input", policy)
            assert_equal policy, updated_policy
        end
        it "does nothing if the transport is zero and MQueues are not available" do
            flexmock(Orocos::MQueue).should_receive(:available?).and_return(false)
            assert_equal Hash[transport: 0], port.handle_mq_transport("input", transport: 0)
        end

        describe "validation of queue length and message size" do
            it "defaults to a buffer size of MQ_RTT_DEFAULT_QUEUE_LENGTH if no size is given" do
                flexmock(Orocos::MQueue).should_receive(:valid_sizes?).
                    with(Orocos::Port::MQ_RTT_DEFAULT_QUEUE_LENGTH, 10, Proc).
                    once.pass_thru
                port.handle_mq_transport("input", transport: 0, data_size: 10)
            end
            it "defaults to a buffer size of MQ_RTT_DEFAULT_QUEUE_LENGTH if the size is zero" do
                flexmock(Orocos::MQueue).should_receive(:valid_sizes?).
                    with(Orocos::Port::MQ_RTT_DEFAULT_QUEUE_LENGTH, 10, Proc).
                    once.pass_thru
                port.handle_mq_transport("input", transport: 0, size: 0, data_size: 10)
            end
            it "validates against the given data size and buffer size" do
                flexmock(Orocos::MQueue).should_receive(:valid_sizes?).
                    with(42, 10, Proc).
                    once.pass_thru
                port.handle_mq_transport("input", transport: 0, size: 42, data_size: 10)
            end
            it "falls back to the original policy if the sizes are not valid and it was the input policy" do
                flexmock(port).should_receive(:max_marshalling_size).and_return(10)
                flexmock(Orocos::MQueue).should_receive(:valid_sizes?).
                    with(42, 10, Proc).once.and_return(false)
                assert_equal Hash[transport: 0, size: 42],
                    port.handle_mq_transport("input", transport: 0, size: 42)

            end
            it "raises if the sizes are not valid and the MQ transport was selected explicitely" do
                flexmock(Orocos::MQueue).should_receive(:valid_sizes?).
                    with(42, 10, Proc).once.and_return(false)
                assert_raises(Orocos::Port::InvalidMQTransportSetup) do
                    port.handle_mq_transport("input", transport: Orocos::TRANSPORT_MQ, size: 42, data_size: 10)
                end
            end
        end

        describe "validation of message size" do
            it "initializes data_size by the value returned by #max_marshalling_size f data_size is zero" do
                flexmock(port).should_receive(:max_marshalling_size).and_return(10)
                flexmock(Orocos::MQueue).should_receive(:validate_sizes?).and_return(false)
                assert_equal Hash[transport: Orocos::TRANSPORT_MQ, size: 42, data_size: 10],
                    port.handle_mq_transport("input", transport: 0, size: 42, data_size: 0)
            end
            it "initializes data_size by the value returned by #max_marshalling_size f data_size is not given" do
                flexmock(port).should_receive(:max_marshalling_size).and_return(10)
                flexmock(Orocos::MQueue).should_receive(:validate_sizes?).and_return(false)
                assert_equal Hash[transport: Orocos::TRANSPORT_MQ, size: 42, data_size: 10],
                    port.handle_mq_transport("input", transport: 0, size: 42)
            end
            it "falls back to the original policy if the max marshalling size cannot be computed" do
                flexmock(port).should_receive(:max_marshalling_size).and_return(nil)
                assert_equal Hash[transport: 0, size: 42],
                    port.handle_mq_transport("input", transport: 0, size: 42)

            end
            it "raises if the max marshalling size cannot be computed and the MQ transport was selected explicitely" do
                flexmock(port).should_receive(:max_marshalling_size).and_return(nil)
                assert_raises(Orocos::Port::InvalidMQTransportSetup) do
                    port.handle_mq_transport("input", transport: Orocos::TRANSPORT_MQ, size: 42)
                end
            end
        end
    end
end

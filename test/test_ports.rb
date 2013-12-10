$LOAD_PATH.unshift File.join(File.dirname(__FILE__), "..", "lib")
require 'minitest/spec'
require 'orocos'
require 'orocos/test'

MiniTest::Unit.autorun

Orocos::CORBA.call_timeout = 10000
Orocos::CORBA.connect_timeout = 10000

TEST_DIR = File.expand_path(File.dirname(__FILE__))
DATA_DIR = File.join(TEST_DIR, 'data')
WORK_DIR = File.join(TEST_DIR, 'working_copy')

DATAFLOW_STRESS_TEST =
    if ENV['DATAFLOW_STRESS_TEST']
        Integer(ENV['DATAFLOW_STRESS_TEST'])
    end

describe Orocos::Port do
    include Orocos::Spec

    it "should not be possible to create an instance directly" do
	assert_raises(NoMethodError) { Orocos::Port.new }
    end

    it "should check equality based on CORBA reference" do
        Orocos.run 'simple_source' do |source|
            source = source.task("source")
            p1 = source.port("cycle")
            # Remove p1 from source's port cache
            source.instance_variable_get("@ports").delete("cycle")
            p2 = source.port("cycle")
            refute_equal(p1.object_id, p2.object_id)
            assert_equal(p1, p2)
        end
    end
end

describe Orocos::OutputPort do
    if !defined? TEST_DIR
        TEST_DIR = File.expand_path(File.dirname(__FILE__))
        DATA_DIR = File.join(TEST_DIR, 'data')
        WORK_DIR = File.join(TEST_DIR, 'working_copy')
    end

    ComError = Orocos::CORBA::ComError

    include Orocos::Spec

    it "should not be possible to create an instance directly" do
	assert_raises(NoMethodError) { Orocos::OutputPort.new }
    end
    
    it "should have the right model" do
        Orocos.run('simple_source') do
            task = Orocos::TaskContext.get('simple_source_source')
            source = task.port("cycle")
            assert_same source.model, task.model.find_output_port('cycle')
        end
    end

    it "should be able to connect to an input" do
        Orocos.run('simple_source', 'simple_sink') do
            source = Orocos::TaskContext.get('simple_source_source').port("cycle")
            sink   = Orocos::TaskContext.get('simple_sink_sink').port("cycle")

            assert(!sink.connected?)
            assert(!source.connected?)
            source.connect_to sink
            assert(sink.connected?)
            assert(source.connected?)
        end
    end

    it "should raise CORBA::ComError when connected to a dead input" do
        Orocos.run('simple_source', 'simple_sink') do |*processes|
            source = Orocos::TaskContext.get('simple_source_source').port("cycle")
            sink   = Orocos::TaskContext.get('simple_sink_sink').port("cycle")
            processes.find { |p| p.name == 'simple_sink' }.kill(true, 'KILL')
            assert_raises(ComError) { source.connect_to sink }
        end
    end

    it "should raise CORBA::ComError when #connect_to is called on a dead process" do
        Orocos.run('simple_source', 'simple_sink') do |*processes|
            source = Orocos::TaskContext.get('simple_source_source').port("cycle")
            sink   = Orocos::TaskContext.get('simple_sink_sink').port("cycle")
            processes.find { |p| p.name == 'simple_source' }.kill(true, 'KILL')
            assert_raises(ComError) { source.connect_to sink }
        end
    end

    it "should be able to disconnect from a particular input" do
        Orocos.run('simple_source', 'simple_sink') do |p_source, p_sink|
            source = Orocos::TaskContext.get('simple_source_source').port("cycle")
            sink   = Orocos::TaskContext.get('simple_sink_sink').port("cycle")

            assert(!source.disconnect_from(sink))
            source.connect_to sink
            assert(sink.connected?)
            assert(source.connected?)
            assert(source.disconnect_from(sink))
            assert(!sink.connected?)
            assert(!source.connected?)
        end
    end

    it "should be able to selectively disconnect a in-process connection" do
        Orocos.run('system') do
            source = Orocos::TaskContext.get('control').cmd_out
            sink   = Orocos::TaskContext.get('motor_controller').command

            assert(!source.disconnect_from(sink))
            source.connect_to sink
            assert(sink.connected?)
            assert(source.connected?)
            assert(source.disconnect_from(sink))
            assert(!sink.connected?)
            assert(!source.connected?)
        end
    end

    it "it should be able to disconnect from a dead input" do
        Orocos.run('simple_source', 'simple_sink') do |*processes|
            source = Orocos::TaskContext.get('simple_source_source').port("cycle")
            sink   = Orocos::TaskContext.get('simple_sink_sink').port("cycle")
            source.connect_to sink
            assert(source.connected?)
            processes.find { |p| p.name == 'simple_sink' }.kill(true, 'KILL')
            assert(source.connected?)
            assert(source.disconnect_from(sink))
            assert(!source.connected?)
        end
    end

    it "should be able to disconnect from all its InputPort" do
        Orocos.run('simple_source', 'simple_sink') do |p_source, p_sink|
            source = Orocos::TaskContext.get('simple_source_source').port("cycle")
            sink   = Orocos::TaskContext.get('simple_sink_sink').port("cycle")

            source.connect_to sink
            assert(sink.connected?)
            assert(source.connected?)
            source.disconnect_all
            assert(!sink.connected?)
            assert(!source.connected?)
        end
    end

    it "it should be able to modify connections while running" do
        last = nil
        Orocos.run('simple_sink', 'simple_source', :output => "%m.log") do
            source_task = Orocos::TaskContext.get("fast_source")
            sources = (0...4).map { |i| source_task.port("out#{i}") }
            sink_task = Orocos::TaskContext.get("fast_sink")
            sinks   = (0...4).map { |i| sink_task.port("in#{i}") }

            count, display = nil
            if DATAFLOW_STRESS_TEST
                count   = DATAFLOW_STRESS_TEST
                display = true
            else
                count = 10_000
            end

            source_task.configure
            source_task.start
            sink_task.start
            count.times do |i|
                p_out = sources[rand(4)]
                p_in  = sinks[rand(4)]
                p_out.connect_to p_in, :pull => (rand > 0.5)
                if rand > 0.8
                    p_out.disconnect_all
                end

                if display && (i % 1000 == 0)
                    if last
                        delay = Time.now - last
                    end
                    last = Time.now
                    STDERR.puts "#{i} #{delay}"
                end
            end
        end
    end

    it "it should be able to disconnect all inputs even though some are dead" do
        Orocos.run('simple_source', 'simple_sink') do |*processes|
            source = Orocos::TaskContext.get('simple_source_source').port("cycle")
            sink   = Orocos::TaskContext.get('simple_sink_sink').port("cycle")
            source.connect_to sink
            assert(source.connected?)
            processes.find { |p| p.name == 'simple_sink' }.kill(true, 'KILL')
            assert(source.connected?)
            source.disconnect_all
            assert(!source.connected?)
        end
    end

    it "should refuse connecting to another OutputPort" do
        Orocos.run('simple_source') do |p_source, p_sink|
            source = Orocos::TaskContext.get('simple_source_source').port("cycle")

            assert(!source.connected?)
            assert_raises(ArgumentError) { source.connect_to source }
        end
    end

    if Orocos::Test::USE_MQUEUE
        it "should fallback to CORBA if connection fails with MQ" do
            begin
                Orocos::MQueue.validate_sizes = false
                Orocos::MQueue.auto_sizes = false
                Orocos.run('simple_source', 'simple_sink') do |p_source, p_sink|
                    source = Orocos::TaskContext.get('simple_source_source').port("cycle")
                    sink   = Orocos::TaskContext.get('simple_sink_sink').port("cycle")
                    source.connect_to sink, :transport => Orocos::TRANSPORT_MQ, :data_size => Orocos::MQueue.msgsize_max + 1, :type => :buffer, :size => 1
                    assert source.connected?
                end
            ensure
                Orocos::MQueue.validate_sizes = true
                Orocos::MQueue.auto_sizes = true
            end
        end
    end
end

describe Orocos::InputPort do
    if !defined? TEST_DIR
        TEST_DIR = File.expand_path(File.dirname(__FILE__))
        DATA_DIR = File.join(TEST_DIR, 'data')
        WORK_DIR = File.join(TEST_DIR, 'working_copy')
    end

    include Orocos::Spec

    it "should not be possible to create an instance directly" do
	assert_raises(NoMethodError) { Orocos::InputPort.new }
    end

    it "should have the right model" do
        Orocos.run('simple_sink') do
            task = Orocos::TaskContext.get('simple_sink_sink')
            port = task.port("cycle")
            assert_same port.model, task.model.find_input_port('cycle')
        end
    end

    it "should be able to disconnect from all connected outputs" do
        Orocos.run('simple_source', 'simple_sink') do |p_source, p_sink|
            source = Orocos::TaskContext.get('simple_source_source').port("cycle")
            sink   = Orocos::TaskContext.get('simple_sink_sink').port("cycle")

            source.connect_to sink
            assert(sink.connected?)
            assert(source.connected?)
            sink.disconnect_all
            assert(!sink.connected?)
            assert(!source.connected?)
        end
    end

    it "should be able to disconnect from all connected outputs even though some are dead" do
        Orocos.run('simple_source', 'simple_sink') do |*processes|
            source = Orocos::TaskContext.get('simple_source_source').port("cycle")
            sink   = Orocos::TaskContext.get('simple_sink_sink').port("cycle")

            source.connect_to sink
            assert(sink.connected?)
            processes.find { |p| p.name == 'simple_source' }.kill(true, 'KILL')
            assert(sink.connected?)
            sink.disconnect_all
            assert(!sink.connected?)
        end
    end

    it "should refuse connecting to another input" do
        Orocos.run('simple_source') do |p_source, p_sink|
            source = Orocos::TaskContext.get('simple_source_source').port("cycle")

            assert(!source.connected?)
            assert_raises(ArgumentError) { source.connect_to source }
        end
    end

    it "it should be able to modify connections while running" do
        last = nil
        Orocos.run('simple_sink', 'simple_source', :output => "%m.log") do
            source_task = Orocos::TaskContext.get("fast_source")
            sources = (0...4).map { |i| source_task.port("out#{i}") }
            sink_task = Orocos::TaskContext.get("fast_sink")
            sinks   = (0...4).map { |i| sink_task.port("in#{i}") }

            count, display = nil
            if DATAFLOW_STRESS_TEST
                count   = DATAFLOW_STRESS_TEST
                display = true
            else
                count = 10_000
            end

            source_task.configure
            source_task.start
            sink_task.start
            count.times do |i|
                p_out = sources[rand(4)]
                p_in  = sinks[rand(4)]
                p_out.connect_to p_in, :pull => (rand > 0.5)
                if rand > 0.8
                    p_in.disconnect_all
                end

                if display && (i % 1000 == 0)
                    if last
                        delay = Time.now - last
                    end
                    last = Time.now
                    STDERR.puts "#{i} #{delay}"
                end
            end
        end
    end
end

describe Orocos::OutputReader do
    if !defined? TEST_DIR
        TEST_DIR = File.expand_path(File.dirname(__FILE__))
        DATA_DIR = File.join(TEST_DIR, 'data')
        WORK_DIR = File.join(TEST_DIR, 'working_copy')
    end

    include Orocos::Spec

    it "should not be possible to create an instance directly" do
	assert_raises(NoMethodError) { Orocos::OutputReader.new }
    end

    it "should offer read access on an output port" do
        Orocos.run('simple_source') do |source|
            source = source.task('source')
            output = source.port('cycle')
            
            # Create a new reader. The default policy is data
            reader = output.reader
            assert(reader.kind_of?(Orocos::OutputReader))
            assert_equal(nil, reader.read) # nothing written yet
        end
    end

    it "should allow to read opaque types" do
        Orocos.run('echo') do |source|
            source = source.task('Echo')
            output = source.port('output_opaque')
            reader = output.reader
            source.configure
            source.start
            source.write_opaque(42)

            sleep(0.2)
            
            # Create a new reader. The default policy is data
            sample = reader.read
            assert_equal(42, sample.x)
            assert_equal(84, sample.y)
        end
    end

    it "should allow reusing a sample" do
        Orocos.run('echo') do |source|
            source = source.task('Echo')
            output = source.port('output_opaque')
            reader = output.reader
            source.configure
            source.start
            source.write_opaque(42)

            sleep(0.2)
            
            # Create a new reader. The default policy is data
            sample = output.new_sample
            returned_sample = reader.read(sample)
            assert_same returned_sample, sample
            assert_equal(42, sample.x)
            assert_equal(84, sample.y)
        end
    end

    it "should be able to read data from an output port using a data connection" do
        Orocos.run('simple_source') do |source|
            source = source.task('source')
            output = source.port('cycle')
            source.configure
            source.start
            
            # The default policy is data
            reader = output.reader
            sleep(0.2)
            assert(reader.read > 1)
        end
    end

    it "should be able to read data from an output port using a buffer connection" do
        Orocos.run('simple_source') do |source|
            source = source.task('source')
            output = source.port('cycle')
            reader = output.reader :type => :buffer, :size => 10
            source.configure
            source.start
            sleep(0.5)
            source.stop

            values = []
            while v = reader.read_new
                values << v
            end
            assert(values.size > 1)
            values.each_cons(2) do |a, b|
                assert(b == a + 1, "non-consecutive values #{a.inspect} and #{b.inspect}")
            end
        end
    end

    it "should be able to read data from an output port using a struct" do
        Orocos.run('simple_source') do |source|
            source = source.task('source')
            output = source.port('cycle_struct')
            reader = output.reader :type => :buffer, :size => 10
            source.configure
            source.start
            sleep(0.5)
            source.stop

            values = []
            while v = reader.read_new
                values << v.value
            end
            assert(values.size > 1)
            values.each_cons(2) do |a, b|
                assert(b == a + 1, "non-consecutive values #{a.inspect} and #{b.inspect}")
            end
        end
    end

    it "should be able to clear its connection" do
        Orocos.run('simple_source') do |source|
            source = source.task('source')
            output = source.port('cycle')
            reader = output.reader
            source.configure
            source.start
            sleep(0.5)
            source.stop

            assert(reader.read)
            reader.clear
            assert(!reader.read)
        end
    end

    it "should raise ComError if the remote end is dead and be disconnected" do
	Orocos.run 'simple_source' do |source_p|
            source = source_p.task('source')
            output = source.port('cycle')
            reader = output.reader
            source.configure
            source.start
            sleep(0.5)

            source_p.kill(true, 'KILL')

	    assert_raises(Orocos::CORBA::ComError) { reader.read }
	    assert(!reader.connected?)
	end
    end

    it "should get an initial value when :init is specified" do
        Orocos.run('echo') do |echo|
            echo  = echo.task('Echo')
            echo.start

            reader = echo.ondemand.reader
            assert(!reader.read, "got data on 'ondemand': #{reader.read}")
            echo.write(10)
            sleep 0.1
            assert_equal(10, reader.read)
            reader = echo.ondemand.reader(:init => true)
            sleep 0.1
            assert_equal(10, reader.read)
        end
    end

    if Orocos::Test::USE_MQUEUE
        it "should fallback to CORBA if connection fails with MQ" do
            begin
                Orocos::MQueue.validate_sizes = false
                Orocos::MQueue.auto_sizes = false
                Orocos.run('echo') do |echo|
                    echo  = echo.task('Echo')
                    reader = echo.ondemand.reader(:transport => Orocos::TRANSPORT_MQ, :data_size => Orocos::MQueue.msgsize_max + 1, :type => :buffer, :size => 1)
                    assert reader.connected?
                end
            ensure
                Orocos::MQueue.validate_sizes = true
                Orocos::MQueue.auto_sizes = true
            end
        end
    end
end

describe Orocos::InputWriter do
    if !defined? TEST_DIR
        TEST_DIR = File.expand_path(File.dirname(__FILE__))
        DATA_DIR = File.join(TEST_DIR, 'data')
        WORK_DIR = File.join(TEST_DIR, 'working_copy')
    end

    CORBA = Orocos::CORBA
    include Orocos::Spec

    it "should not be possible to create an instance directly" do
	assert_raises(NoMethodError) { Orocos::InputWriter.new }
    end

    it "should offer write access on an input port" do
        Orocos.run('echo') do |echo|
            echo  = echo.task('Echo')
            input = echo.port('input')
            
            writer = input.writer
            assert_kind_of Orocos::InputWriter, writer
            writer.write(0)
        end
    end

    it "should raise Corba::ComError when writing on a dead port and be disconnected" do
        Orocos.run('echo') do |echo_p|
            echo  = echo_p.task('Echo')
            input = echo.port('input')
            
            writer = input.writer
            echo_p.kill(true, 'KILL')
	    assert_raises(CORBA::ComError) { writer.write(0) }
	    assert(!writer.connected?)
        end
    end

    it "should be able to write data to an input port using a data connection" do
        Orocos.run('echo') do |echo|
            echo  = echo.task('Echo')
            writer = echo.port('input').writer
            reader = echo.port('output').reader

            echo.start
            assert_equal(nil, reader.read)
            writer.write(10)
            sleep(0.1)
            assert_equal(10, reader.read)
        end
    end

    it "should be able to write structs using a Hash" do
        Orocos.run('echo') do |echo|
            echo  = echo.task('Echo')
            writer = echo.port('input_struct').writer
            reader = echo.port('output').reader

            echo.start
            assert_equal(nil, reader.read)
            writer.write(:value => 10)
            sleep(0.1)
            assert_equal(10, reader.read)
        end
    end

    it "should allow to write opaque types" do
        Orocos.run('echo') do |echo|
            echo  = echo.task('Echo')
            writer = echo.port('input_opaque').writer
            reader = echo.port('output_opaque').reader

            echo.start

            writer.write(:x => 84, :y => 42)
            sleep(0.2)
            sample = reader.read
            assert_equal(84, sample.x)
            assert_equal(42, sample.y)

            sample = writer.new_sample
            sample.x = 20
            sample.y = 10
            writer.write(sample)
            sleep(0.2)
            sample = reader.read
            assert_equal(20, sample.x)
            assert_equal(10, sample.y)
        end
    end

    if Orocos::Test::USE_MQUEUE
        it "should fallback to CORBA if connection fails with MQ" do
            begin
                Orocos::MQueue.validate_sizes = false
                Orocos::MQueue.auto_sizes = false
                Orocos.run('echo') do |echo|
                    echo  = echo.task('Echo')
                    writer = echo.port('input_opaque').writer(:transport => Orocos::TRANSPORT_MQ, :data_size => Orocos::MQueue.msgsize_max + 1, :type => :buffer, :size => 1)
                    assert writer.connected?
                end
            ensure
                Orocos::MQueue.validate_sizes = true
                Orocos::MQueue.auto_sizes = true
            end
        end
    end

    describe "#connect_to" do
        it "should raise if the provided policy is invalid" do
            producer = Orocos::RubyTaskContext.new 'producer'
            out_p = producer.create_output_port 'out', 'double'
            consumer = Orocos::RubyTaskContext.new 'consumer'
            in_p = consumer.create_input_port 'in', 'double'
            assert_raises(ArgumentError) do
                out_p.connect_to in_p, :type=>:pull,
                    :init=>false,
                    :pull=>false,
                    :data_size=>0,
                    :size=>0,
                    :lock=>:lock_free,
                    :transport=>0,
                    :name_id=>""
            end
        end
    end
end


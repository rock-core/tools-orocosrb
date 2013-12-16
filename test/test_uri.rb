require 'minitest/spec'
require 'orocos'
require 'orocos/uri'
require 'orocos/test'
require 'orocos/async'

Orocos::CORBA.name_service.ip = "127.0.0.1"

MiniTest::Unit.autorun

TEST_DIR = File.expand_path(File.dirname(__FILE__))
DATA_DIR = File.join(TEST_DIR, 'data')
WORK_DIR = File.join(TEST_DIR, 'working_copy')

describe URI::Orocos do 
    include Orocos::Spec

    describe "form_port_proxy" do 
        it "can be created from port" do
            Orocos.run('simple_source') do
                task = Orocos::Async.proxy("simple_source_source")
                port = task.port("cycle")
                port.wait
                uri = URI::Orocos.from_port(port)
                assert_equal task.name,uri.task_name
                assert_equal port.name,uri.port_name
                assert_equal port.orocos_type_name,uri.hash[:type_name]
                assert uri.port_proxy?
                assert uri.task_proxy?
            end
        end
    end
    describe "parse" do
        it "can handle an absolute task name" do
            uri = URI.parse("OROCOS:/port//namespace/simple_source_source.cycle?type_name=/int32_t")
            assert_equal "/namespace/simple_source_source",uri.task_name
            assert_equal "cycle",uri.port_name
            assert_equal "/int32_t",uri.hash[:type_name]
            assert uri.port_proxy?
        end

        it "can handle a relative task name" do
            uri = URI.parse("OROCOS:/port/namespace/simple_source_source.cycle?type_name=/int32_t")
            assert_equal "namespace/simple_source_source",uri.task_name
            assert_equal "cycle",uri.port_name
            assert_equal "/int32_t",uri.hash[:type_name]
            assert uri.port_proxy?
        end

        it "can handle a task name without namespace" do
            uri = URI.parse("OROCOS:/port/simple_source_source.cycle?type_name=/int32_t")
            assert_equal "simple_source_source",uri.task_name
            assert_equal "cycle",uri.port_name
            assert_equal "/int32_t",uri.hash[:type_name]
            assert uri.port_proxy?
        end
    end

    describe "task" do
        it "can be parsed from string" do
            Orocos.run('simple_source') do
                uri = URI.parse("OROCOS:/port/simple_source_source.cycle?type_name=/int32_t")
                task = uri.task_proxy
                task.wait
                assert task.reachable?
            end
        end
    end
end

require 'minitest/spec'
require 'rack/test'
require 'orocos'
require 'orocos/test'
require 'orocos/webapi'
require 'rack'

describe Orocos::WebAPI::Tasks do
    include Orocos::Spec
    include Rack::Test::Methods

    before do
        Orocos::CORBA.name_service.ip = 'localhost'
        if !Orocos.initialized?
            Orocos.initialize
        end
    end

    def app
        @app ||= Orocos::WebAPI::Root.new
    end

    def with_stub_task_context(task_name)
        ruby_task = Orocos::RubyTaskContext.new task_name
        yield(ruby_task)
    ensure
        ruby_task.dispose if ruby_task
    end

    describe "/tasks" do
        describe "GET /" do
            it "returns an empty array" do
                get "/tasks"
                assert_equal 200, last_response.status
                assert_equal Hash['task_names' => []], MultiJson.load(last_response.body)
            end

            describe "extended_info" do
                it "returns an empty array" do
                    get "/tasks?extended_info=true"
                    assert_equal 200, last_response.status
                    assert_equal Hash['tasks' => []], MultiJson.load(last_response.body)
                end

                it "returns the name and model name of a given task" do
                    with_stub_task_context "task" do |task|
                        get "/tasks?extended_info=true"
                        assert_equal 200, last_response.status
                        expected = Hash[name: 'localhost/task', model: Hash[name: ''], state: 'STOPPED']
                        assert_equal Hash[tasks: [expected]],
                                          MultiJson.load(last_response.body, symbolize_keys: true)
                    end
                end
            end
        end

        describe "GET /:namespace/:name" do
            it "returns a code 404 if the name does not exist" do
                get "/tasks/localhost/task/does_not_exist"
                assert_equal 404, last_response.status
            end

            it "returns the task name and model name" do
                with_stub_task_context "task" do |task|
                    get "/tasks/localhost/task"
                    assert_equal 200, last_response.status
                    expected = Hash[name: 'localhost/task', model: Hash[name: ''], state: 'STOPPED']
                    assert_equal Hash[task: expected],
                        MultiJson.load(last_response.body, symbolize_keys: true)
                end
            end
        end

        describe "GET /:namespace/:name/ports" do
            it "returns a code 404 if the task does not exist" do
                get "/tasks/localhost/does_not_exist/ports"
                assert_equal 404, last_response.status
            end

            it "returns the list of all ports" do
                with_stub_task_context "task" do |task|
                    port = task.create_output_port 'port', '/double'
                    get "/tasks/localhost/task/ports"
                    assert_equal 200, last_response.status
                    expected = [Hash[direction: 'output', name: 'port',
                                    type: {name: '/double', class: 'Typelib::NumericType', size: 8, integer: false}]]
                    assert_equal Hash[ports: expected], MultiJson.load(last_response.body, symbolize_keys: true)
                end
            end
        end

        describe "GET /:namespace/:name/ports/:port" do
            it "returns a code 404 if the task does not exist" do
                get "/tasks/localhost/does_not_exist/ports/port_does_not_exist"
                assert_equal 404, last_response.status
            end
            it "returns a code 404 if the task does exist but not the port" do
                with_stub_task_context "task" do |task|
                    get "/tasks/localhost/task/ports/port_does_not_exist"
                    assert_equal 404, last_response.status
                end
            end

            it "returns the port model" do
                with_stub_task_context "task" do |task|
                    port = task.create_output_port 'port', '/double'
                    get "/tasks/localhost/task/ports/port"
                    assert_equal 200, last_response.status
                    expected = Hash[direction: 'output', name: 'port',
                                    type: {name: '/double', class: 'Typelib::NumericType', size: 8, integer: false}]
                    assert_equal Hash[port: expected], MultiJson.load(last_response.body, symbolize_keys: true)
                end
            end

            describe "/read" do
                it "returns a code 408 if no data is received within the expected time" do
                    with_stub_task_context "task" do |task|
                        port = task.create_output_port 'port', '/double'
                        get "/tasks/localhost/task/ports/port/read?timeout=0.05"
                        assert_equal 408, last_response.status
                    end
                end
                it "returns the received sample" do
                    with_stub_task_context "task" do |task|
                        port = task.create_output_port 'port', '/double'
                        flexmock(Orocos.ruby_task).should_receive(:create_input_port).
                            and_return(flexmock(:raw_read => flexmock(:to_simple_value => 10.0),
                                :resolve_connection_from => true, :port= => nil, :policy= => nil))
                        get "/tasks/localhost/task/ports/port/read?timeout=0.05"
                        assert_equal 200, last_response.status
                        assert_equal Hash[sample: 10], MultiJson.load(last_response.body, symbolize_keys: true)
                    end
                end
            end
        end
    end
end


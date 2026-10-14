require 'orocos/test'

module Orocos
    describe ComponentLoader do
        before do
            @loader = Orocos::ComponentLoader.new
        end

        describe "create_local_task_context" do
            it "raises if the component type does not exist" do
                assert_raises(ArgumentError) do
                    @loader.create_local_task_context("mylogger", "does_not_exist", false)
                end
            end
        end

        it "creates a dynamically loaded component" do
            @loader.load_task_library "logger"
            local_task_context = @loader.create_local_task_context(
                "mylogger", "logger::Logger", false
            )
            tc = Orocos::TaskContext.new(local_task_context.ior)
            assert_equal "mylogger", tc.name
        end
    end
end

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), "..", "lib")
require 'minitest/spec'
require 'orocos'
require 'orocos/test'
require 'fakefs/safe'

MiniTest::Unit.autorun

TEST_DIR = File.expand_path(File.dirname(__FILE__))
DATA_DIR = File.join(TEST_DIR, 'data')
WORK_DIR = File.join(TEST_DIR, 'working_copy')

describe Orocos::TaskConfigurations do
    include Orocos::Spec
    include Orocos::Test::Mocks
    TaskConfigurations = Orocos::TaskConfigurations

    attr_reader :conf
    attr_reader :model

    def setup
        super
        @model = Orocos.task_model_from_name('configurations::Task')
        @conf  = TaskConfigurations.new(model)
    end

    def verify_loaded_conf(conf, name = nil, *base_path)
        if conf.respond_to?(:sections)
            assert conf.sections.has_key?(name)
            @conf_context = conf.sections[name]
        else
            @conf_context = conf
            if name
                base_path.unshift name
            end
        end

        @conf_getter = method(:get_conf_value)
        base_path.each do |p|
            @conf_context = @conf_context[p]
        end
        yield
    end

    def verify_apply_conf(task, conf, names, *base_path, &block)
        conf.apply(task, names)
        verify_applied_conf(task, *base_path, &block)
    end

    def verify_applied_conf(task, *base_path)
        if !base_path.empty?
            base_property = task.property(base_path.shift)
            value_path = base_path
        end

        @conf_getter = lambda do |*path|
            property=
                if base_property then base_property
                else
                    task.property(path.shift)
                end

            result = property.raw_read
            (base_path + path).inject(result) do |result, field|
                result.raw_get(field)
            end
        end
        yield
    end

    def get_conf_value(*path)
        path.inject(@conf_context) do |result, field|
            if !result[field]
                raise ArgumentError, "no #{field} in #{result.inspect}"
            end
            result[field]
        end
    end

    def assert_conf_value(*path)
        expected_value = path.pop
        type = path.pop
        type_name = path.pop

        value = @conf_getter[*path]
        assert_kind_of type, value
        assert_equal type_name, value.class.name

        if block_given?
            value = yield(value)
        elsif value.kind_of?(Typelib::Type)
            value = Typelib.to_ruby(value)
        end
        assert_equal expected_value, value
    end

    it "should be able to load simple configuration structures" do
        conf.load_from_yaml(File.join(DATA_DIR, 'configurations', 'base_config.yml'))
        assert_equal %w{compound default simple_container}, conf.sections.keys.sort

        verify_loaded_conf conf, 'default' do
            assert_conf_value 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'intg', "/int32_t", Typelib::NumericType, 20
            assert_conf_value 'str', "/std/string", Typelib::ContainerType, "test"
            assert_conf_value 'fp', '/double', Typelib::NumericType, 0.1
        end

        verify_loaded_conf conf, 'compound', 'compound' do
            assert_conf_value 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 'intg', "/int32_t", Typelib::NumericType, 30
            assert_conf_value 'str', "/std/string", Typelib::ContainerType, "test2"
            assert_conf_value 'fp', '/double', Typelib::NumericType, 0.2
            assert_conf_value 'simple_array', 0, "/int32_t", Typelib::NumericType, 1
            assert_conf_value 'simple_array', 1, "/int32_t", Typelib::NumericType, 2
            assert_conf_value 'simple_array', 2, "/int32_t", Typelib::NumericType, 3
            array = get_conf_value 'simple_array'
            assert_equal 3, array.size
        end

        verify_loaded_conf conf, 'simple_container', 'simple_container' do
            assert_conf_value 0, "/int32_t", Typelib::NumericType, 10
            assert_conf_value 1, "/int32_t", Typelib::NumericType, 20
            assert_conf_value 2, "/int32_t", Typelib::NumericType, 30
            container = get_conf_value
            assert_equal 3, container.size
        end
    end

    it "should be able to load dynamic configuration structures" do
        conf.load_from_yaml(File.join(DATA_DIR, 'configurations', 'dynamic_config.yml'))
        assert_equal %w{compound default simple_container}, conf.sections.keys.sort

        verify_loaded_conf conf, 'default' do
            assert_conf_value 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'intg', "/int32_t", Typelib::NumericType, 20
            assert_conf_value 'str', "/std/string", Typelib::ContainerType, "test"
            assert_conf_value 'fp', '/double', Typelib::NumericType, 0.1
            assert_conf_value 'bl', '/bool', Typelib::NumericType, true
        end

        verify_loaded_conf conf, 'compound', 'compound' do
            assert_conf_value 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 'intg', "/int32_t", Typelib::NumericType, 30
            assert_conf_value 'str', "/std/string", Typelib::ContainerType, ".yml"
            assert_conf_value 'fp', '/double', Typelib::NumericType, 0.2
            assert_conf_value 'simple_array', 0, "/int32_t", Typelib::NumericType, 1
            assert_conf_value 'simple_array', 1, "/int32_t", Typelib::NumericType, 2
            assert_conf_value 'simple_array', 2, "/int32_t", Typelib::NumericType, 3
            array = get_conf_value 'simple_array'
            assert_equal 3, array.size
        end

        verify_loaded_conf conf, 'simple_container', 'simple_container' do
            assert_conf_value 0, "/int32_t", Typelib::NumericType, 10
            assert_conf_value 1, "/int32_t", Typelib::NumericType, 20
            assert_conf_value 2, "/int32_t", Typelib::NumericType, 30
            container = get_conf_value
            assert_equal 3, container.size
        end
    end

    it "should be able to load complex structures" do
        conf.load_from_yaml(File.join(DATA_DIR, 'configurations', 'complex_config.yml'))

        verify_loaded_conf conf, 'compound_in_compound', 'compound', 'compound' do
            assert_conf_value 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 'intg', "/int32_t", Typelib::NumericType, 30
            assert_conf_value 'str', "/std/string", Typelib::ContainerType, "test2"
            assert_conf_value 'fp', '/double', Typelib::NumericType, 0.2
        end

        verify_loaded_conf conf, 'vector_of_compound', 'compound', 'vector_of_compound' do
            assert_conf_value 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 0, 'intg', "/int32_t", Typelib::NumericType, 10
            assert_conf_value 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 1, 'intg', "/int32_t", Typelib::NumericType, 20
            assert_conf_value 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 2, 'intg', "/int32_t", Typelib::NumericType, 30
        end

        verify_loaded_conf conf, 'vector_of_vector_of_compound', 'compound', 'vector_of_vector_of_compound' do
            assert_conf_value 0, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 0, 0, 'intg', "/int32_t", Typelib::NumericType, 10
            assert_conf_value 0, 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 0, 1, 'intg', "/int32_t", Typelib::NumericType, 20
            assert_conf_value 0, 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 0, 2, 'intg', "/int32_t", Typelib::NumericType, 30
            assert_conf_value 1, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 1, 0, 'intg', "/int32_t", Typelib::NumericType, 11
            assert_conf_value 1, 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 1, 1, 'intg', "/int32_t", Typelib::NumericType, 21
            assert_conf_value 1, 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 1, 2, 'intg', "/int32_t", Typelib::NumericType, 31
        end

        verify_loaded_conf conf, 'array_of_compound', 'compound', 'array_of_compound' do
            assert_conf_value 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 0, 'intg', "/int32_t", Typelib::NumericType, 10
            assert_conf_value 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 1, 'intg', "/int32_t", Typelib::NumericType, 20
            assert_conf_value 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 2, 'intg', "/int32_t", Typelib::NumericType, 30
        end

        verify_loaded_conf conf, 'array_of_vector_of_compound', 'compound', 'array_of_vector_of_compound' do
            assert_conf_value 0, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 0, 0, 'intg', "/int32_t", Typelib::NumericType, 10
            assert_conf_value 0, 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 0, 1, 'intg', "/int32_t", Typelib::NumericType, 20
            assert_conf_value 0, 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 0, 2, 'intg', "/int32_t", Typelib::NumericType, 30
            assert_conf_value 1, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 1, 0, 'intg', "/int32_t", Typelib::NumericType, 11
            assert_conf_value 1, 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 1, 1, 'intg', "/int32_t", Typelib::NumericType, 21
            assert_conf_value 1, 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 1, 2, 'intg', "/int32_t", Typelib::NumericType, 31
        end
    end

    it "should be able to merge configuration structures" do
        conf.load_from_yaml(File.join(DATA_DIR, 'configurations', 'merge.yml'))
        result = conf.conf(['default', 'add'], false)
        verify_loaded_conf result do
            assert_conf_value 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'intg', "/int32_t", Typelib::NumericType, 20
        end
        verify_loaded_conf result, 'compound' do
            assert_conf_value 'compound', 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 'compound', 'intg', "/int32_t", Typelib::NumericType, 30
            assert_conf_value 'vector_of_compound', 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'vector_of_compound', 0, 'intg', "/int32_t", Typelib::NumericType, 10
            assert_conf_value 'vector_of_compound', 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 'array_of_vector_of_compound', 0, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'array_of_vector_of_compound', 0, 0, 'intg', "/int32_t", Typelib::NumericType, 10
            assert_conf_value 'array_of_vector_of_compound', 0, 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 'array_of_vector_of_compound', 0, 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 'array_of_vector_of_compound', 1, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'array_of_vector_of_compound', 1, 0, 'intg', "/int32_t", Typelib::NumericType, 12
            assert_conf_value 'array_of_vector_of_compound', 2, 0, 'enm', "/Enumeration", Typelib::EnumType, :Second
        end
    end

    it "merge without overrides should have the same result than with if no conflicts exist" do
        conf.load_from_yaml(File.join(DATA_DIR, 'configurations', 'merge.yml'))
        result = conf.conf(['default', 'add'], false)
        result_with_override = conf.conf(['default', 'add'], true)
        assert_equal result, result_with_override
    end

    it "should be able to detect invalid overridden values" do
        conf.load_from_yaml(File.join(DATA_DIR, 'configurations', 'merge.yml'))
        # Make sure that nothing is raised if override is false
        conf.conf(['default', 'override'], true)
        assert_raises(ArgumentError) { conf.conf(['default', 'override'], false) }
    end

    it "should be able to merge with overrides" do
        conf.load_from_yaml(File.join(DATA_DIR, 'configurations', 'merge.yml'))
        result = conf.conf(['default', 'override'], true)

        verify_loaded_conf result do
            assert_conf_value 'intg', "/int32_t", Typelib::NumericType, 25
        end
        verify_loaded_conf result, 'compound' do
            assert_conf_value 'compound', 'intg', "/int32_t", Typelib::NumericType, 30
            assert_conf_value 'vector_of_compound', 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'vector_of_compound', 0, 'intg', "/int32_t", Typelib::NumericType, 42
            assert_conf_value 'vector_of_compound', 1, 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 'vector_of_compound', 1, 'intg', "/int32_t", Typelib::NumericType, 22
            assert_conf_value 'array_of_vector_of_compound', 0, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'array_of_vector_of_compound', 0, 0, 'intg', "/int32_t", Typelib::NumericType, 10
            assert_conf_value 'array_of_vector_of_compound', 0, 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 'array_of_vector_of_compound', 0, 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 'array_of_vector_of_compound', 1, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'array_of_vector_of_compound', 1, 0, 'intg', "/int32_t", Typelib::NumericType, 11
            assert_conf_value 'array_of_vector_of_compound', 2, 0, 'enm', "/Enumeration", Typelib::EnumType, :Second
        end
    end

    it "should be able to apply simple configurations on the task" do
        conf.load_from_yaml(File.join(DATA_DIR, 'configurations', 'base_config.yml'))
        Orocos.run "configurations_test" do
            task = Orocos::TaskContext.get "configurations"

            assert_equal (0...10).to_a, task.simple_container.to_a
            assert_equal :First, task.compound.enm
            simple_array = task.compound.simple_array.to_a
            simple_container = task.simple_container.to_a

            conf.apply(task, 'default')

            assert_equal (0...10).to_a, task.simple_container.to_a
            assert_equal :First, task.compound.enm
            verify_applied_conf task do
                assert_conf_value 'enm', "/Enumeration", Typelib::EnumType, :First
                assert_conf_value 'intg', "/int32_t", Typelib::NumericType, 20
                assert_conf_value 'str', "/std/string", Typelib::ContainerType, "test"
                assert_conf_value 'fp', '/double', Typelib::NumericType, 0.1
            end


            conf.apply(task, ['default', 'compound'])
            verify_applied_conf task do
                assert_conf_value 'enm', "/Enumeration", Typelib::EnumType, :First
                assert_conf_value 'intg', "/int32_t", Typelib::NumericType, 20
                assert_conf_value 'str', "/std/string", Typelib::ContainerType, "test"
                assert_conf_value 'fp', '/double', Typelib::NumericType, 0.1
            end
            simple_array[0, 3] = [1, 2, 3]
            verify_applied_conf task, 'compound' do
                assert_conf_value 'enm', "/Enumeration", Typelib::EnumType, :Second
                assert_conf_value 'intg', "/int32_t", Typelib::NumericType, 30
                assert_conf_value 'str', "/std/string", Typelib::ContainerType, "test2"
                assert_conf_value 'fp', '/double', Typelib::NumericType, 0.2
                assert_conf_value 'simple_array', '/int32_t[10]', Typelib::ArrayType, simple_array do |v|
                    v.to_a
                end
            end

            conf.apply(task, ['default', 'compound', 'simple_container'])
            simple_container[0, 3] = [10, 20, 30]
            verify_applied_conf task do
                assert_conf_value 'simple_container', '/std/vector</int32_t>', Typelib::ContainerType, simple_container do |v|
                    v.to_a
                end
            end
        end
    end

    it "should be able to apply complex configuration on the task" do
        conf.load_from_yaml(File.join(DATA_DIR, 'configurations', 'complex_config.yml'))

        Orocos.run "configurations_test" do
            task = Orocos::TaskContext.get "configurations"

            verify_apply_conf task, conf, 'compound_in_compound', 'compound', 'compound' do
                assert_conf_value 'enm', "/Enumeration", Typelib::EnumType, :Third
                assert_conf_value 'intg', "/int32_t", Typelib::NumericType, 30
                assert_conf_value 'str', "/std/string", Typelib::ContainerType, "test2"
                assert_conf_value 'fp', '/double', Typelib::NumericType, 0.2
            end

            verify_apply_conf task, conf, 'vector_of_compound', 'compound', 'vector_of_compound' do
                assert_conf_value 0, 'enm', "/Enumeration", Typelib::EnumType, :First
                assert_conf_value 0, 'intg', "/int32_t", Typelib::NumericType, 10
                assert_conf_value 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
                assert_conf_value 1, 'intg', "/int32_t", Typelib::NumericType, 20
                assert_conf_value 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
                assert_conf_value 2, 'intg', "/int32_t", Typelib::NumericType, 30
            end

            verify_apply_conf task, conf, 'vector_of_vector_of_compound', 'compound', 'vector_of_vector_of_compound' do
                assert_conf_value 0, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
                assert_conf_value 0, 0, 'intg', "/int32_t", Typelib::NumericType, 10
                assert_conf_value 0, 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
                assert_conf_value 0, 1, 'intg', "/int32_t", Typelib::NumericType, 20
                assert_conf_value 0, 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
                assert_conf_value 0, 2, 'intg', "/int32_t", Typelib::NumericType, 30
                assert_conf_value 1, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
                assert_conf_value 1, 0, 'intg', "/int32_t", Typelib::NumericType, 11
                assert_conf_value 1, 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
                assert_conf_value 1, 1, 'intg', "/int32_t", Typelib::NumericType, 21
                assert_conf_value 1, 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
                assert_conf_value 1, 2, 'intg', "/int32_t", Typelib::NumericType, 31
            end

            verify_apply_conf task, conf, 'array_of_compound', 'compound', 'array_of_compound' do
                assert_conf_value 0, 'enm', "/Enumeration", Typelib::EnumType, :First
                assert_conf_value 0, 'intg', "/int32_t", Typelib::NumericType, 10
                assert_conf_value 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
                assert_conf_value 1, 'intg', "/int32_t", Typelib::NumericType, 20
                assert_conf_value 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
                assert_conf_value 2, 'intg', "/int32_t", Typelib::NumericType, 30
            end

            verify_apply_conf task, conf, 'array_of_vector_of_compound', 'compound', 'array_of_vector_of_compound' do
                assert_conf_value 0, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
                assert_conf_value 0, 0, 'intg', "/int32_t", Typelib::NumericType, 10
                assert_conf_value 0, 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
                assert_conf_value 0, 1, 'intg', "/int32_t", Typelib::NumericType, 20
                assert_conf_value 0, 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
                assert_conf_value 0, 2, 'intg', "/int32_t", Typelib::NumericType, 30
                assert_conf_value 1, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
                assert_conf_value 1, 0, 'intg', "/int32_t", Typelib::NumericType, 11
                assert_conf_value 1, 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
                assert_conf_value 1, 1, 'intg', "/int32_t", Typelib::NumericType, 21
                assert_conf_value 1, 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
                assert_conf_value 1, 2, 'intg', "/int32_t", Typelib::NumericType, 31
            end
        end
    end

    it "should be able to load a configuration directory, register configurations on a per-model basis, and report what changed" do
        manager = Orocos::ConfigurationManager.new
        manager.load_dir(File.join(DATA_DIR, 'configurations', 'dir'))
        result = manager.conf['configurations::Task'].conf(['default', 'add'], false)

        verify_loaded_conf result do
            assert_conf_value 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'intg', "/int32_t", Typelib::NumericType, 20
        end
        verify_loaded_conf result, 'compound' do
            assert_conf_value 'compound', 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 'compound', 'intg', "/int32_t", Typelib::NumericType, 30
            assert_conf_value 'vector_of_compound', 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'vector_of_compound', 0, 'intg', "/int32_t", Typelib::NumericType, 10
            assert_conf_value 'vector_of_compound', 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 'array_of_vector_of_compound', 0, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'array_of_vector_of_compound', 0, 0, 'intg', "/int32_t", Typelib::NumericType, 10
            assert_conf_value 'array_of_vector_of_compound', 0, 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 'array_of_vector_of_compound', 0, 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 'array_of_vector_of_compound', 1, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'array_of_vector_of_compound', 1, 0, 'intg', "/int32_t", Typelib::NumericType, 12
            assert_conf_value 'array_of_vector_of_compound', 2, 0, 'enm', "/Enumeration", Typelib::EnumType, :Second
        end

        assert_equal(Hash.new, manager.load_dir(File.join(DATA_DIR, 'configurations', 'dir')))
        assert_equal({'configurations::Task' => ['default']}, manager.load_dir(File.join(DATA_DIR, 'configurations', 'dir_changed')))
        result = manager.conf['configurations::Task'].conf(['default', 'add'], false)

        verify_loaded_conf result do
            assert_conf_value 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'intg', "/int32_t", Typelib::NumericType, 0
        end
        verify_loaded_conf result, 'compound' do
            assert_conf_value 'compound', 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 'compound', 'intg', "/int32_t", Typelib::NumericType, 30
            assert_conf_value 'vector_of_compound', 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'vector_of_compound', 0, 'intg', "/int32_t", Typelib::NumericType, 10
            assert_conf_value 'vector_of_compound', 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 'array_of_vector_of_compound', 0, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'array_of_vector_of_compound', 0, 0, 'intg', "/int32_t", Typelib::NumericType, 10
            assert_conf_value 'array_of_vector_of_compound', 0, 1, 'enm', "/Enumeration", Typelib::EnumType, :Second
            assert_conf_value 'array_of_vector_of_compound', 0, 2, 'enm', "/Enumeration", Typelib::EnumType, :Third
            assert_conf_value 'array_of_vector_of_compound', 1, 0, 'enm', "/Enumeration", Typelib::EnumType, :First
            assert_conf_value 'array_of_vector_of_compound', 1, 0, 'intg', "/int32_t", Typelib::NumericType, 12
            assert_conf_value 'array_of_vector_of_compound', 2, 0, 'enm', "/Enumeration", Typelib::EnumType, :Second
        end
    end

    describe "typelib_from_yaml_array" do
        attr_reader :array_t, :vector_t
        before do
            registry = Typelib::CXXRegistry.new
            @array_t = registry.create_array "/double", 2
            @vector_t = registry.create_container "/std/vector", "/double"
        end

        it "should resize a smaller container" do
            vector = vector_t.new
            Orocos::TaskConfigurations.typelib_from_yaml_array(vector, [1, 2, 3])
            assert_equal 3, vector.size
            assert_equal 1, vector[0]
            assert_equal 2, vector[1]
            assert_equal 3, vector[2]
        end
        it "should keep a bigger container to its current size" do
            vector = Typelib.from_ruby([1, 2], vector_t)
            Orocos::TaskConfigurations.typelib_from_yaml_array(vector, [-1])
            assert_equal 2, vector.size
            assert_equal -1, vector[0]
            assert_equal 2, vector[1]
        end
        it "should only set the relevant values on a bigger array" do
            array = Typelib.from_ruby([1, 2], array_t)
            Orocos::TaskConfigurations.typelib_from_yaml_array(array, [-1])
            assert_equal -1, array[0]
            assert_equal 2, array[1]
        end
        it "should raise ArgumentError if the array is too small" do
            array = Typelib.from_ruby([1, 2], array_t)
            assert_raises(ArgumentError) do
                Orocos::TaskConfigurations.typelib_from_yaml_array(array, [0, 1, 2])
            end
        end
    end

    describe "#load_dir" do
        attr_reader :conf
        before do
            FakeFS.activate!
            @conf = flexmock(Orocos::ConfigurationManager.new)
        end
        after do
            FakeFS.deactivate!
            FakeFS::FileSystem.clear
        end
        it "should raise ArgumentError if the directory does not exist" do
            assert_raises(ArgumentError) { conf.load_dir "/does/not/exist" }
        end
        it "should ignore entries that are not files" do
            FileUtils.mkdir_p "/conf/entry.yml"
            conf.should_receive(:load_file).never
            conf.load_dir "/conf"
        end
        it "should ignore entries whose model cannot be found" do
            FileUtils.mkdir_p "/conf"
            File.open("/conf/entry.yml", 'w').close
            conf.should_receive(:load_file).with("/conf/entry.yml").and_raise(Orocos::NotFound)
            # Should not raise
            conf.load_dir "/conf"
        end
        it "should return a hash from model name to section list if some sections got added or modified" do
            FileUtils.mkdir_p "/conf"
            File.open("/conf/first.yml", 'w').close
            File.open("/conf/second.yml", 'w').close
            conf.should_receive(:load_file).with("/conf/first.yml").
                and_return("task::Model" => ['section'])
            conf.should_receive(:load_file).with("/conf/second.yml").
                and_return("task::Model" => ['other_section'])
            # Should not raise
            assert_equal Hash["task::Model" => ['section', 'other_section']], conf.load_dir("/conf")
        end
    end

    describe "#load_file" do
        attr_reader :conf
        before do
            FakeFS.activate!
            FileUtils.mkdir_p "/conf"
            @conf = flexmock(Orocos::ConfigurationManager.new)
        end
        after do
            FakeFS.deactivate!
            FakeFS::FileSystem.clear
        end
        it "should raise ArgumentError if the file does not exist" do
            assert_raises(ArgumentError) { conf.load_file "/does/not/exist" }
        end
        it "should allow to specify the model name manually" do
            File.open("/conf/first.yml", 'w').close
            conf.load_file "/conf/first.yml", "configurations::Task"
            flexmock(Orocos).should_receive(:task_model_from_name).with("task::Model").
                pass_thru
        end
        it "should infer the model name if it is not given" do
            File.open("/conf/configurations::Task.yml", 'w').close
            conf.load_file "/conf/configurations::Task.yml"
            flexmock(Orocos).should_receive(:task_model_from_name).with("task::Model").
                pass_thru
        end
        it "should raise Orocos::NotFound if the model does not exist" do
            File.open("/conf/first.yml", 'w').close
            assert_raises(Orocos::NotFound) { conf.load_file "/conf/first.yml", "does_not::Exist" }
        end
        it "should return false if no sections got added or modified" do
            File.open("/conf/configurations::Task.yml", 'w').close
            conf.load_file "/conf/configurations::Task.yml"
            assert !conf.load_file("/conf/configurations::Task.yml")
        end
        it "should return a hash from model name to section list if some sections got added or modified" do
            File.open("/conf/file.yml", 'w') do |io|
                io.puts "--- name:test"
            end
            assert_equal Hash["configurations::Task" => ["test"]],
                conf.load_file("/conf/file.yml", "configurations::Task")
        end
    end
end

class TC_Orocos_Configurations < Test::Unit::TestCase
    include Orocos::Test

    def setup
        super
        Orocos.load
    end

    def test_merge_conf_array
        assert_raises(ArgumentError) { TaskConfigurations.merge_conf_array([nil, 1], [nil, 2], false) }
        assert_equal([1, 2], TaskConfigurations.merge_conf_array([1, nil], [nil, 2], false))
        assert_equal([nil, 2], TaskConfigurations.merge_conf_array([nil, 1], [nil, 2], true))
        assert_equal([1, 2], TaskConfigurations.merge_conf_array([], [1, 2], false))
        assert_equal([1, 2], TaskConfigurations.merge_conf_array([], [1, 2], true))

        assert_equal([1, 2], TaskConfigurations.merge_conf_array([1], [nil, 2], false))
        assert_equal([1, 2], TaskConfigurations.merge_conf_array([1], [nil, 2], true))
        assert_equal([1, 4, 3, 5], TaskConfigurations.merge_conf_array([1, 2, 3], [nil, 4, nil, 5], true))
        assert_equal([1, 2], TaskConfigurations.merge_conf_array([1, 2], [1, 2], false))
        assert_equal([1, 2], TaskConfigurations.merge_conf_array([1, 2], [1, 2], true))
    end

    def test_override_arrays
        if !Orocos.registry.include?('/base/Vector3d')
            Orocos.registry.create_compound('/base/Vector3d') do |t|
                t.data = '/double[4]'
            end
        end

        model = mock_task_context_model do
            property 'gyrorw', '/base/Vector3d'
            property 'gyrorrw', '/base/Vector3d'
        end

        conf = Orocos::TaskConfigurations.new(model)
        default_conf = {
            'gyrorrw' => {
                'data' => [2.65e-06, 4.01e-06, 5.19e-06]
            },
            'gyrorw' => {
                'data' => [6.04E-05, 6.94E-05, 5.96E-05]
            }
        }
        conf.add('default', default_conf)

        xsens_conf = {
            'gyrorw' => {
                'data' => [0.0006898864, 0.0007219069, 0.0005708627]
            }
        }
        conf.add('mti_xsens', xsens_conf)

        result = conf.conf(['default', 'default'], true)
        assert_equal(default_conf, result)

        result = conf.conf(['default', 'mti_xsens'], true)
        assert_equal({ 'gyrorrw' => default_conf['gyrorrw'], 'gyrorw' => xsens_conf['gyrorw'] }, result)
    end
end


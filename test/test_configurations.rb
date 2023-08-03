require 'orocos/test'
require 'fakefs/safe'

describe Orocos::TaskConfigurations do
    include Orocos::Spec

    attr_reader :conf
    attr_reader :model

    def setup
        super
        @model = Orocos.default_loader.task_model_from_name('configurations::Task')
        @conf  = Orocos::TaskConfigurations.new(model)
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
            if result.respond_to?(:raw_get)
                result.raw_get(field)
            else
                result.fetch(field)
            end
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
        conf.load_from_yaml(File.join(data_dir, 'configurations', 'base_config.yml'))
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
        conf.load_from_yaml(File.join(data_dir, 'configurations', 'dynamic_config.yml'))
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

    describe "the loaded yaml cache" do
        before do
            @root_dir  = make_tmpdir
            @cache_dir  = FileUtils.mkdir File.join(@root_dir, 'cache')
            @conf_file = File.join(@root_dir, "conf.yml")
            write_fixture_conf <<~CONF
            --- name:default
            intg: 20
            CONF
        end
        def write_fixture_conf(content)
            File.open(@conf_file, 'w') { |io| io.write(content) }
        end
        it "auto-saves a marshalled version in the provided cache directory" do
            @conf.load_from_yaml(@conf_file, cache_dir: @cache_dir)
            flexmock(YAML).should_receive(:load).never
            conf = Orocos::TaskConfigurations.new(model)
            conf.load_from_yaml(@conf_file, cache_dir: @cache_dir)
            default = conf.conf('default')
            assert_equal 20, Typelib.to_ruby(default['intg'])
        end
        it "ignores the cache if the document changed" do
            # Generate the cache
            @conf.load_from_yaml(@conf_file, cache_dir: @cache_dir)
            write_fixture_conf <<~CONF
            --- name:default
            intg: 30
            CONF

            flexmock(YAML).should_receive(:load).at_least.once.pass_thru
            conf = Orocos::TaskConfigurations.new(model)
            conf.load_from_yaml(@conf_file, cache_dir: @cache_dir)
            default = conf.conf('default')
            assert_equal 30, Typelib.to_ruby(default['intg'])
        end
        it "does not use the cache if the dynamic content is different" do
            write_fixture_conf <<~CONF
            --- name:default
            intg: <%= Time.now.tv_usec %>
            CONF
            @conf.load_from_yaml(@conf_file, cache_dir: @cache_dir)
            flexmock(YAML).should_receive(:load).at_least.once.pass_thru
            conf = Orocos::TaskConfigurations.new(model)
            conf.load_from_yaml(@conf_file, cache_dir: @cache_dir)
        end
        it "properly deals with an invalid cache" do
            write_fixture_conf <<~CONF
            --- name:default
            intg: 20
            CONF
            @conf.load_from_yaml(@conf_file, cache_dir: @cache_dir)
            Dir.glob(File.join(@cache_dir, "*")) do |file|
                File.truncate(file, 0) if File.file?(file)
            end
            conf = Orocos::TaskConfigurations.new(model)
            conf.load_from_yaml(@conf_file, cache_dir: @cache_dir)
            default = conf.conf('default')
            assert_equal 20, Typelib.to_ruby(default['intg'])
        end
    end

    it "raises if the same section is defined twice in the same file" do
        assert_raises(ArgumentError) do
            conf.load_from_yaml(
                File.join(data_dir, "configurations", "duplicate_sections.yml")
            )
        end
    end

    it "raises even if the duplicate section is the implicit default section" do
        assert_raises(ArgumentError) do
            conf.load_from_yaml(
                File.join(data_dir, "configurations", "duplicate_default.yml")
            )
        end
    end

    it "ignores a no-op default section at the top of the file" do
        conf.load_from_yaml(
            File.join(data_dir, "configurations", "noop_default.yml")
        )
    end

    it "should be able to load complex structures" do
        conf.load_from_yaml(File.join(data_dir, 'configurations', 'complex_config.yml'))

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

    describe "#conf" do
        it "merges configuration structures" do
            conf.load_from_yaml(File.join(data_dir, 'configurations', 'merge.yml'))
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
            conf.load_from_yaml(File.join(data_dir, 'configurations', 'merge.yml'))
            result = conf.conf(['default', 'add'], false)
            result_with_override = conf.conf(['default', 'add'], true)
            assert_equal result, result_with_override
        end

        it "raises ArgumentError if conflicts exist and override is false" do
            conf.load_from_yaml(File.join(data_dir, 'configurations', 'merge.yml'))
            # Make sure that nothing is raised if override is false
            conf.conf(['default', 'override'], true)
            assert_raises(ArgumentError) { conf.conf(['default', 'override'], false) }
        end

        it "raises SectionNotFound if given an unknown section" do
            assert_raises(Orocos::TaskConfigurations::SectionNotFound) { conf.conf(['default', 'does_not_exist'], false) }
        end

        it "accepts a 'default' section even if it does not exist" do
            assert_equal Hash.new, conf.conf(['default'], false)
        end

        it "accepts a single string as section name" do
            assert_equal Hash.new, conf.conf('default', false)
        end

        it "takes values from the last section if conflicts exist and override is true" do
            conf.load_from_yaml(File.join(data_dir, 'configurations', 'merge.yml'))
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
    end

    describe "#conf_as_ruby" do
        it "converts the configuration to a name-to-ruby value mapping" do
            conf.load_from_yaml(File.join(data_dir, 'configurations', 'merge.yml'))
            result = conf.conf_as_ruby(['default', 'add'], override: false)
            assert_same :First, result['enm']
        end
    end

    describe "#conf_as_typelib" do
        it "converts the configuration to a name-to-typelib value mapping" do
            conf.load_from_yaml(File.join(data_dir, 'configurations', 'merge.yml'))
            result = conf.conf_as_typelib(['default', 'add'], override: false)
            assert_equal '/Enumeration', result['enm'].class.name
            assert_equal :First, Typelib.to_ruby(result['enm'])
        end
    end


    it "should be able to apply simple configurations on the task" do
        conf.load_from_yaml(File.join(data_dir, 'configurations', 'base_config.yml'))

        start 'configurations::Task' => 'configurations'
        task = Orocos.get "configurations"

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
        simple_container = [10, 20, 30]
        verify_applied_conf task do
            assert_conf_value 'simple_container', '/std/vector</int32_t>', Typelib::ContainerType, simple_container do |v|
                v.to_a
            end
        end
    end

    it "should be able to apply complex configuration on the task" do
        conf.load_from_yaml(File.join(data_dir, 'configurations', 'complex_config.yml'))

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

    it "zeroes out newly created structures and initializes fields that need to" do
        conf.load_from_yaml(File.join(data_dir, 'configurations', 'complex_config.yml'))

        Orocos.run "configurations_test" do
            task = Orocos::TaskContext.get "configurations"

            verify_apply_conf task, conf, 'zero_and_init', 'compound', 'vector_of_compound' do
                assert_conf_value 0, 'enm', "/Enumeration", Typelib::EnumType, :Second
                assert_conf_value 0, 'intg', "/int32_t", Typelib::NumericType, 0
                assert_conf_value 1, 'enm', "/Enumeration", Typelib::EnumType, :First
                assert_conf_value 1, 'intg', "/int32_t", Typelib::NumericType, 20
            end
        end
    end

    it "should be able to load a configuration directory, register configurations on a per-model basis, and report what changed" do
        manager = Orocos::ConfigurationManager.new
        manager.load_dir(File.join(data_dir, 'configurations', 'dir'))
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

        assert_equal(Hash.new, manager.load_dir(File.join(data_dir, 'configurations', 'dir')))
        assert_equal({'configurations::Task' => ['default']}, manager.load_dir(File.join(data_dir, 'configurations', 'dir_changed')))
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

    describe "#add" do
        before do
            manager = Orocos::ConfigurationManager.new
            manager.load_dir(File.join(data_dir, 'configurations', 'dir'))
            @conf = manager.conf['configurations::Task']
        end

        describe "merge: true" do
            it "merges into an existing section" do
                assert @conf.add 'default', Hash['compound' => Hash['compound' => Hash['intg' => 20]]], merge: true
                assert_equal 20, @conf.conf('default')['compound']['compound']['intg'].to_ruby
                assert_equal 10, @conf.conf('default')['compound']['vector_of_compound'][0]['intg'].to_ruby
            end
            it "returns false if the updated value is equal to the existing one" do
                refute @conf.add 'default', Hash['compound' => Hash['compound' => Hash['intg' => 30]]], merge: true
            end
            it "updates the cached value returned by #conf" do
                @conf.conf('default')
                @conf.add 'default', Hash['compound' => Hash['compound' => Hash['intg' => 20]]], merge: true
                assert_equal 20, @conf.conf('default')['compound']['compound']['intg'].to_ruby
            end
        end
        describe "merge: false" do
            it "replaces an existing section" do
                assert @conf.add 'default', Hash['compound' => Hash['compound' => Hash['intg' => 20]]], merge: false
                assert_equal 20, @conf.conf('default')['compound']['compound']['intg'].to_ruby
                assert_nil @conf.conf('default')['compound']['vector_of_compound']
            end
            it "updates the cached value returned by #conf" do
                @conf.conf('default')
                @conf.add 'default', Hash['compound' => Hash['compound' => Hash['intg' => 20]]], merge: false
                assert_equal 20, @conf.conf('default')['compound']['compound']['intg'].to_ruby
            end
        end
        it "adds a new section if the added section does not exist" do
            assert @conf.add 'does_not_already_exist', Hash['compound' => Hash['compound' => Hash['intg' => 20]]], merge: false
            assert_equal 20, @conf.conf('does_not_already_exist')['compound']['compound']['intg'].to_ruby
        end
    end

    describe "apply_conf_on_typelib_value" do
        attr_reader :array_t, :vector_t
        before do
            registry = Typelib::CXXRegistry.new
            @array_t = registry.create_array "/double", 2
            @vector_t = registry.create_container "/std/vector", "/double"
        end

        it "should resize a smaller container" do
            vector = vector_t.new
            Orocos::TaskConfigurations.apply_conf_on_typelib_value(vector, [1, 2, 3])
            assert_equal 3, vector.size
            assert_equal 1, vector[0]
            assert_equal 2, vector[1]
            assert_equal 3, vector[2]
        end
        it "should keep a bigger container to its current size" do
            vector = Typelib.from_ruby([1, 2], vector_t)
            Orocos::TaskConfigurations.apply_conf_on_typelib_value(vector, [-1])
            assert_equal 2, vector.size
            assert_equal -1, vector[0]
            assert_equal 2, vector[1]
        end
        it "should only set the relevant values on a bigger array" do
            array = Typelib.from_ruby([1, 2], array_t)
            Orocos::TaskConfigurations.apply_conf_on_typelib_value(array, [-1])
            assert_equal -1, array[0]
            assert_equal 2, array[1]
        end
        it "should raise ArgumentError if the array is too small" do
            array = Typelib.from_ruby([1, 2], array_t)
            assert_raises(ArgumentError) do
                Orocos::TaskConfigurations.apply_conf_on_typelib_value(array, [0, 1, 2])
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
            conf.should_receive(:load_file).with("/conf/entry.yml").and_raise(OroGen::TaskModelNotFound)
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
        it "should raise OroGen::TaskModelNotFound if the model does not exist" do
            File.open("/conf/first.yml", 'w').close
            assert_raises(OroGen::TaskModelNotFound) { conf.load_file "/conf/first.yml", "does_not::Exist" }
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

    describe "evaluate_numeric_field" do
        attr_reader :float_t, :int_t
        before do
            registry = Typelib::CXXRegistry.new
            @float_t = registry.get '/float'
            @int_t   = registry.get '/int'
        end

        describe "plain values" do
            it "leaves integer values as-is" do
                assert_equal 10, conf.evaluate_numeric_field(10, int_t)
            end
            it "floors integer types, but issues a warning" do
                flexmock(Orocos::ConfigurationManager).should_receive(:warn).once
                assert_equal 9, conf.evaluate_numeric_field(9.7, int_t)
            end
            it "leaves floating-point values as-is" do
                assert_in_delta 9.2, conf.evaluate_numeric_field(9.2, float_t), 0.000001
            end
        end

        describe "plain values represented as strings" do
            it "leaves integer values as-is" do
                assert_equal 10, conf.evaluate_numeric_field('10', int_t)
            end
            it "floors by default for integer types, but emits a warning" do
                flexmock(Orocos::ConfigurationManager).should_receive(:warn).once
                assert_equal 9, conf.evaluate_numeric_field('9.7', int_t)
            end
            it "allows to specify the rounding mode for integer types" do
                assert_equal 9, conf.evaluate_numeric_field('9.7.floor', int_t)
                assert_equal 10, conf.evaluate_numeric_field('9.2.ceil', int_t)
                assert_equal 10, conf.evaluate_numeric_field('9.7.round', int_t)
            end
            it "leaves floating-point values as-is" do
                assert_in_delta 9.2, conf.evaluate_numeric_field('9.2', float_t), 0.000001
            end
            it "handles exponent specifications in floating-point values" do
                assert_in_delta 9.2e-3, conf.evaluate_numeric_field('9.2e-3', float_t), 0.000001
            end
        end

        describe "values with units" do
            it "converts a plain unit to the corresponding SI representation" do
                assert_in_delta 10 * Math::PI / 180,
                    conf.evaluate_numeric_field("10.deg", float_t), 0.0001
            end
            it "handles power-of-units" do
                assert_in_delta 10 * (Math::PI / 180) ** 2,
                    conf.evaluate_numeric_field("10.deg^2", float_t), 0.0001
            end
            it "handles unit scales" do
                assert_in_delta 10 * 0.001 * (Math::PI / 180),
                    conf.evaluate_numeric_field("10.mdeg", float_t), 0.0001
            end
            it "handles full specifications" do
                assert_in_delta 10 / (0.001 * Math::PI / 180) ** 2 * 0.01 ** 3,
                    conf.evaluate_numeric_field("10.mdeg^-2.cm^3", float_t), 0.0001
            end
        end
    end

    describe "normalize_conf_value" do
        attr_reader :registry
        before do
            @registry = Typelib::CXXRegistry.new
        end

        it "maps the elements of a ruby array if the sizes do not match" do
            type = registry.build('/int[5]')
            result = conf.normalize_conf_value([1, 2, 3, 4], type)
            assert_kind_of Array, result
            result.each do |e|
                assert_kind_of type.deference, e
            end
            assert_equal [1, 2, 3, 4], result.map { |e| Typelib.to_ruby(e) }
        end
        it "maps arrays to a typelib array if the sizes match" do
            type = registry.build('/int[5]')
            result = conf.normalize_conf_value([1, 2, 3, 4, 5], type)
            assert_kind_of type, result
            assert_equal [1, 2, 3, 4, 5], result.to_a
        end
        it "maps hashes passing on the field types" do
            type = registry.create_compound '/Test' do |c|
                c.add 'f0', '/int'
                c.add 'f1', '/std/string'
            end
            result = conf.normalize_conf_value(Hash['f0' => 1, 'f1' => 'a_string'], type)
            result.each do |k, v|
                assert_kind_of type[k], v
            end
            assert_equal Hash['f0' => 1, 'f1' => 'a_string'], Typelib.to_ruby(result)
        end
        it "converts numerical values using evaluate_numeric_field" do
            type = registry.get '/int'
            flexmock(conf).should_receive(:evaluate_numeric_field).
                with('42', type).and_return(42).once
            result = conf.normalize_conf_value('42', type)
            assert_kind_of type, result
            assert_equal 42, Typelib.to_ruby(result)
        end
        it "converts /std/string as a final value instead of a container" do
            string_t = registry.get '/std/string'
            normalized = conf.normalize_conf_value("bla", string_t)
            assert_kind_of string_t, normalized
            assert_equal "bla", Typelib.to_ruby(normalized)
        end
        it "keeps typelib compound values that match the target value" do
            compound_t = registry.create_compound('/S') { |c| c.add 'a', '/int' }
            compound = compound_t.new(a: 10)
            normalized = conf.normalize_conf_value(compound, compound_t)
            assert_equal compound, normalized
        end
        it "normalizes a compound's field" do
            compound_t = registry.create_compound('/S') { |c| c.add 'a', '/int' }
            compound = compound_t.new(a: 10)
            normalized = conf.normalize_conf_value(Hash['a' => compound.a], compound_t)
            assert_equal compound.a, normalized['a']
        end
        it "keeps typelib container values" do
            container_t = registry.create_container('/std/vector', '/int')
            container = container_t.new
            container << 0
            normalized = conf.normalize_conf_value(container, container_t)
            assert_kind_of container_t, normalized
            normalized.raw_each { |v| assert_kind_of(container_t.deference, v) }
            normalized.raw_each.each_with_index { |v, i| assert_equal(container[i], v) }
        end
        it "keeps typelib array values" do
            array_t = registry.create_array('/int', 3)
            array = array_t.new
            normalized = conf.normalize_conf_value(array, array_t)
            assert_kind_of array_t, normalized
            normalized.raw_each { |v| assert_kind_of(array_t.deference, v) }
            normalized.raw_each.each_with_index { |v, i| assert_equal(array[i], v) }
        end
        it "properly handles Ruby objects that are converted from a complex Typelib type" do
            klass = Class.new
            compound_t = registry.create_compound('/S') { |c| c.add 'a', '/int' }
            compound_t.convert_from_ruby(klass) { |v| compound_t.new(a: 10) }
            normalized = conf.normalize_conf_value(klass.new, compound_t)
            assert_kind_of compound_t, normalized
            assert_kind_of compound_t['a'], normalized.raw_get('a')
            assert_equal 10, normalized['a']
        end

        describe "conversion error handling" do
            attr_reader :type

            before do
                registry = Typelib::CXXRegistry.new
                inner_compound_t = registry.create_compound '/Test' do |c|
                    c.add 'in_f', '/std/string'
                end
                array_t = registry.create_array inner_compound_t, 2
                @type = registry.create_compound '/OuterTest' do |c|
                    c.add 'out_f', array_t
                end
            end

            it "reports the exact point at which a conversion error occurs" do
                bad_value = Hash[
                    'out_f' => Array[
                        Hash['in_f' => 'string'], Hash['in_f' => 10]
                    ]
                ]
                e = assert_raises(Orocos::TaskConfigurations::ConversionFailed) do
                    conf.normalize_conf_value(bad_value, type)
                end
                assert_equal %w{.out_f [1] .in_f}, e.full_path
                assert(/\.out_f\[1\]\.in_f/ === e.message)
            end
            it "reports the exact point at which an unknown field has been found" do
                bad_value = Hash[
                    'out_f' => Array[
                        Hash['in_f' => 'string'], Hash['f' => 10]
                    ]
                ]
                e = assert_raises(Orocos::TaskConfigurations::ConversionFailed) do
                    conf.normalize_conf_value(bad_value, type)
                end
                assert_equal %w{.out_f [1]}, e.full_path
                assert(/\.out_f\[1\]/ === e.message)
            end
            it "validates array sizes" do
                bad_value = Hash[
                    'out_f' => Array[
                        Hash['in_f' => 'string'], Hash['in_f' => 'blo'], Hash['in_f' => 'bla']
                    ]
                ]
                e = assert_raises(Orocos::TaskConfigurations::ConversionFailed) do
                    conf.normalize_conf_value(bad_value, type)
                end
                assert_equal %w{.out_f}, e.full_path
                assert(/\.out_f/ === e.message)
            end
        end
    end

    describe "#save" do
        describe "#save(task)" do
            attr_reader :task
            before do
                start 'configurations::Task' => 'task'
                @task = Orocos.get 'task'
                # We must load all properties before we activate FakeFS
                task.each_property do |p|
                    v = p.new_sample
                    p.write v
                end
                flexmock(conf).should_receive(:save).
                    with(task, FlexMock.any, FlexMock.any).
                    pass_thru
            end

            it "warns about deprecation" do
                flexmock(Orocos).should_receive(:warn).once
                flexmock(conf).should_receive(:save).
                    with('sec', FlexMock.any, FlexMock.any).
                    once
                conf.save(task, '/conf.yml', 'sec')
            end

            it "extracts the task's configuration and saves it to disk" do
                flexmock(Orocos).should_receive(:warn)
                expected_conf = conf.normalize_conf(Orocos::TaskConfigurations.read_task_conf(task))
                flexmock(conf).should_receive(:save).
                    with('sec', '/conf.yml', task_model: task.model).
                    once.
                    and_return(ret = flexmock)
                assert_same ret, conf.save(task, '/conf.yml', 'sec')
                assert_equal expected_conf, conf.conf('sec')
            end
        end

        describe "#save(name, file)" do
            attr_reader :section
            before do
                @section = Hash['enm' => 'First']
                conf.add 'sec', section
            end
            it "saves the named configuration to disk" do
                flexmock(Orocos::TaskConfigurations).should_receive(:save).
                    with(conf.conf('sec'), '/conf.yml', 'sec', task_model: conf.model, replace: false).
                    once
                conf.save('sec', '/conf.yml')
            end
            it "allows to override the model" do
                task_model = flexmock
                flexmock(Orocos::TaskConfigurations).should_receive(:save).
                    with(conf.conf('sec'), '/conf.yml', 'sec', task_model: task_model, replace: false).
                    once
                conf.save('sec', '/conf.yml', task_model: task_model)
            end
        end
    end

    describe ".save" do
        describe ".save(task)" do
            attr_reader :task, :expected
            before do
                start 'configurations::Task' => 'task'
                @task = Orocos.get 'task'
                # We must load all properties before we activate FakeFS
                task.each_property do |p|
                    p.write p.new_sample
                end
                conf = Orocos::TaskConfigurations.new(task.model)
                @expected = conf.normalize_conf(Orocos::TaskConfigurations.read_task_conf(task))
            end

            it "extracts the configuration from the task and saves it" do
                flexmock(Orocos::TaskConfigurations).
                    should_receive(:save).once.
                    with(task, '/conf.yml', 'sec', task_model: task.model).
		    pass_thru
                flexmock(Orocos::TaskConfigurations).
                    should_receive(:save).once.
                    with(expected, '/conf.yml', 'sec', replace: false, task_model: task.model)
                Orocos::TaskConfigurations.save(task, '/conf.yml', 'sec', task_model: task.model)
            end
        end

        describe ".save(config)" do
            before do
                FakeFS.activate!
            end
            after do
                FakeFS.deactivate!
                FakeFS::FileSystem.clear
            end

            it "creates the target directory" do
                config = Hash['enm' => 'First']
                Orocos::TaskConfigurations.save(config, '/config/conf.yml', 'sec')
                assert File.directory?('/config')
            end
            it "saves the task's configuration file into the specified file and section" do
                config = Hash['enm' => 'First']
                Orocos::TaskConfigurations.save(config, '/conf.yml', 'sec')
                conf.load_from_yaml '/conf.yml'
                c = conf.conf(['sec'])
                assert(c.keys == ['enm'])
                assert(:First == Typelib.to_ruby(c['enm']), "mismatch: #{config} != #{c}")
            end
            it "adds the property's documentation to the saved file" do
                model.find_property('enm').doc('this is a documentation string')
                config = Hash['enm' => 'First']
                Orocos::TaskConfigurations.save(config, '/conf.yml', 'sec', task_model: model)
                data = File.readlines('/conf.yml')
                _, idx = data.each_with_index.find { |line, idx| line.strip == "# this is a documentation string" }
                assert data[idx + 1].strip =~ /^enm:/
            end
            it "appends the documentation to an existing file" do
                config = Hash['enm' => 'First']
                Orocos::TaskConfigurations.save(config, '/conf.yml', 'first')
                Orocos::TaskConfigurations.save(config, '/conf.yml', 'second')
                conf.load_from_yaml '/conf.yml'
                assert conf.has_section?('first')
                assert conf.has_section?('second')
            end
            it "uses the model's name as default file name" do
                config = Hash['enm' => :First]
                conf_dir = File.expand_path(File.join('conf', 'dir'))
                model = OroGen::Spec::TaskContext.blank('model::Name')
                expected_filename = File.join(conf_dir, "#{model.name}.yml")

                FileUtils.mkdir_p conf_dir
                Orocos::TaskConfigurations.save(config, expected_filename, 'sec', task_model: model)
                conf.load_from_yaml expected_filename
                enm = Typelib.to_ruby(conf.conf('sec')['enm'])
                assert(Typelib.to_ruby(enm) == :First)
            end
            it "uses #to_yaml to normalize the configuration hash" do
                config = flexmock
                conf_dir = File.expand_path(File.join('conf', 'dir'))
                model = OroGen::Spec::TaskContext.blank('model::Name')
                expected_filename = File.join(conf_dir, "#{model.name}.yml")

                FileUtils.mkdir_p conf_dir
                flexmock(Orocos::TaskConfigurations).should_receive(:to_yaml).
                    with(config).and_return('enm' => :First)
                Orocos::TaskConfigurations.save(config, expected_filename, 'sec', task_model: model)
                conf.load_from_yaml expected_filename
                enm = Typelib.to_ruby(conf.conf('sec')['enm'])
                assert(Typelib.to_ruby(enm) == :First)
            end
        end

        describe "#to_yaml" do
            before do
                @registry = Typelib::Registry.new
                @numeric_t   = @registry.create_numeric '/int', 4, :sint
                @converted_t = converted_t = @registry.create_compound '/with_convertion' do |c|
                    c.add 'f', '/int'
                end
                @converted_ruby_t = converted_ruby_t = Class.new do
                    attr_accessor :value
                    def initialize(v = 0); @value = v end
                end

                @converted_t.convert_to_ruby(@converted_ruby_t) { |v| converted_ruby_t.new(v.f) }
                @converted_t.convert_from_ruby(@converted_ruby_t) { |v| converted_t.new(f: v.value) }
            end
            it "applies the conversion from converted types in compounds" do
                compound_t = @registry.create_compound '/C' do |c|
                    c.add 'f', @converted_t
                end
                compound = compound_t.new(f: @converted_t.new(f: 0))
                compound.f.value = 42
                assert_equal Hash['f' => Hash['f' => 42]], Orocos::TaskConfigurations.to_yaml(compound)
            end
        end
    end
end

class TC_Orocos_Configurations < Minitest::Test
    TaskConfigurations = Orocos::TaskConfigurations

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
            type_m = Orocos.registry.create_compound('/base/Vector3d') do |t|
                t.data = '/double[4]'
            end
            Orocos.default_loader.register_type_model(type_m)
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

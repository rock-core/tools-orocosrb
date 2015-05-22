require 'orocos/test'

describe "reading and writing properties on TaskContext" do
    describe "#==" do
        attr_reader :task, :prop
        before do
            start 'process::Test' => 'test'
            @task = get 'test'
            @prop = task.property('prop1')
        end

        it "returns true if comparing the same property object" do
            assert_equal prop, prop
        end
        it "returns false for two different properties from the same task" do
            refute_equal prop, task.property('prop2')
        end
        it "returns false for two different properties from two different tasks" do
            start 'process::Test' => 'other'
            refute_equal prop, get('other').property('prop2')
        end
        it "returns false if compared with an arbitrary object" do
            refute_equal flexmock, prop
        end
        it "returns true for the same property represented from two different objects" do
            assert_equal prop, get('test').property('prop1')
        end
    end

    it "should be able to enumerate its properties" do
        start 'process::Test' => 'test'
        t = get 'test'
        assert_equal %w{dynamic_prop dynamic_prop_setter_called prop1 prop2 prop3}, t.property_names.sort
        assert_equal %w{dynamic_prop dynamic_prop_setter_called prop1 prop2 prop3}, t.each_property.map(&:name).sort
        %w{dynamic_prop prop1 prop2 prop3}.each do |name|
            t.has_property?(name)
        end
    end

    it "should be able to read string property values" do
        Orocos.run('process') do |process|
            prop = process.task('Test').property('prop3')
            assert_equal('42', prop.read)
        end
    end

    it "should be able to read property values from a simple type" do
        Orocos.run('process') do |process|
            prop = process.task('Test').property('prop2')
            assert_equal(84, prop.read)
        end
    end

    it "should be able to read property values from a complex type" do
        Orocos.run('process') do |process|
            prop1 = process.task('Test').property('prop1')

            value = prop1.read
            assert_equal(21, value.a)
            assert_equal(42, value.b)
        end
    end

    it "should be able to write a property of a simple type" do
        Orocos.run('process') do |process|
            prop = process.task('Test').property('prop2')
            prop.write(80)
            assert_equal(80, prop.read)
        end
    end

    it "should be able to write string property values" do
        Orocos.run('process') do |process|
            prop = process.task('Test').property('prop3')
            prop.write('84')
            assert_equal('84', prop.read)
        end
    end

    it "should be able to write a property of a complex type" do
        Orocos.run('process') do |process|
            prop = Orocos::TaskContext.get('process_Test').property('prop1')

            value = prop.type.new
            value.a = 22
            value.b = 43
            prop.write(value)

            value = prop.read
            assert_equal(22, value.a)
            assert_equal(43, value.b)
        end
    end

    it "should not call the setter operation of a dynamic property if the task is not configured" do
        start 'process::Test' => 'test'
        task = get 'test'
        task.cleanup
        task.dynamic_prop = '12345'
        refute task.dynamic_prop_setter_called
    end

    it "should call the setter operation of a dynamic property if the task is configured" do
        start 'process::Test' => 'test'
        task = get 'test'
        task.configure
        task.dynamic_prop = '12345'
        assert task.dynamic_prop_setter_called
    end

    it "should raise PropertyChangeRejected if the setter operation returned false" do
        start 'process::Test' => 'test'
        task = get 'test'
        task.configure
        assert_raises(Orocos::PropertyChangeRejected) do
            task.dynamic_prop = ''
        end
        assert_equal '', task.dynamic_prop
        assert task.dynamic_prop_setter_called
    end
end

describe "reading and writing attributes on TaskContext" do
    describe "#==" do
        attr_reader :task, :prop
        before do
            start 'process::Test' => 'test'
            @task = get 'test'
            @prop = task.property('prop1')
        end

        it "returns true if comparing the same property object" do
            assert_equal prop, prop
        end
        it "returns false for two different properties from the same task" do
            refute_equal prop, task.property('prop2')
        end
        it "returns false for two different properties from two different tasks" do
            start 'process::Test' => 'other'
            refute_equal prop, get('other').property('prop2')
        end
        it "returns false if compared with an arbitrary object" do
            refute_equal flexmock, prop
        end
        it "returns true for the same property represented from two different objects" do
            assert_equal prop, get('test').property('prop1')
        end
    end

    it "should be able to enumerate its attributes" do
        Orocos.run('process') do |process|
            t = process.task('Test')
            assert_equal %w{att1 att2 att3}, t.attribute_names.sort
            assert_equal %w{att1 att2 att3}, t.each_attribute.map(&:name).sort
            %w{att1 att2 att3}.each do |name|
                t.has_attribute?(name)
            end
        end
    end

    it "should be able to read string attribute values" do
        Orocos.run('process') do |process|
            att = process.task('Test').attribute('att3')
            assert_equal('42', att.read)
        end
    end

    it "should be able to read attribute values from a simple type" do
        Orocos.run('process') do |process|
            att = process.task('Test').attribute('att2')
            assert_equal(84, att.read)
        end
    end

    it "should be able to read attribute values from a complex type" do
        Orocos.run('process') do |process|
            att1 = process.task('Test').attribute('att1')

            value = att1.read
            assert_equal(21, value.a)
            assert_equal(42, value.b)
        end
    end

    it "should be able to write a attribute of a simple type" do
        Orocos.run('process') do |process|
            att = process.task('Test').attribute('att2')
            att.write(80)
            assert_equal(80, att.read)
        end
    end

    it "should be able to write string attribute values" do
        Orocos.run('process') do |process|
            att = process.task('Test').attribute('att3')
            att.write('84')
            assert_equal('84', att.read)
        end
    end

    it "should be able to write a attribute of a complex type" do
        Orocos.run('process') do |process|
            att = Orocos::TaskContext.get('process_Test').attribute('att1')

            value = att.type.new
            value.a = 22
            value.b = 43
            att.write(value)

            value = att.read
            assert_equal(22, value.a)
            assert_equal(43, value.b)
        end
    end
end



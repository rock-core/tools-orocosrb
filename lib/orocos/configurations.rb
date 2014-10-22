require 'stringio'
require 'yaml'
module Orocos
    # Class handling multiple possible configuration for a single task
    #
    # It can load configuration files that are structured as follows:
    #
    # A configuration file is a YAML file that contains multiple sections. Each
    # section starts with --- and can contain options of the form
    # option_name:value. The section header can be omitted for the very first
    # section
    #
    # For instance
    #
    #   --- name:default merge:true chain:default,test
    #
    # The following options are possible:
    #
    # name:: 
    #   it is optional for the first section and mandatory for further
    #   sections. It gives a name to the section, that can then be used
    #   to refer to the configuration information in TaskConfigurations#apply
    #   and TaskConfigurations#conf. If ommitted for the first section, the name
    #   'default' is used
    # merge::
    #   If set to true, the section will be merged with previous configuration
    #   data previously stored under the same name. Otherwise, it replaces
    #   existing information. The default is false.
    # chain::
    #   If set, it has to be a comma-separated list of configuration names. It
    #   tells the configuration class that this configuration section should
    #   always be merged with the ones listed. The name of the current
    #   configuration section can be listed, in which case it will be merged in
    #   the specified order. Otherwise, it is added at the end.
    # 
    class TaskConfigurations
        # The known configuration sections for this task context model
        #
        # Configuration sections are formatted as follows:
        #  - compounds are represented by hashes
        #  - arrays and containers are represented by arrays
        #  - all other values are represented by the corresponding typelib value
        #
        # This formatting allows to properly perform configuration merging, for
        # instance when one selects the ('default', 'specific') configuration.
        # Indeed, the compounds-represented-by-hashes only hold the values that
        # are explicitly set in the input configuration hash. The nil entries in
        # the arrays also allow to not override already set values.
        #
        # The toplevel value (i.e. the value of e.g. sections['default']) is
        # always a hash whose keys are the task's property names.
        #
        # @return [{String=>{String=>Object}}] 
        attr_reader :sections

        # @return [{String=>Hash}] set of configuration options for each known
        #   configuration sections
        attr_reader :conf_options

        # @return [OroGen::Spec::TaskContext] the task context model for which self holds
        #   configurations
        attr_reader :model

        def initialize(task_model)
            @model = task_model
            @sections = Hash.new
            @merged_conf = Hash.new
        end

        # Retrieves the configuration for the given section name 
        #
        # @return [Object] see the description of {#sections} for the description
        #   of formatting
        def [](section_name)
            sections[section_name]
        end

        # Evaluate ruby content that has been embedded into the configuration file
        # inbetween <%= ... %>
        def evaluate_dynamic_content(filename, value)
            ruby_content = ""
            begin
                # non greedy matching of dynamic code
                value.gsub!(/<%=((.|\n)*?)%>/) do |match|
                    if match =~ /<%=((.|\n)*?)%>/
                        ruby_content = $1.strip
                        p = Proc.new {}
                        eval(ruby_content, p.binding, filename)
                    else
                        match
                    end
                end
            rescue Exception => e
                raise e, "error evaluating dynamic content '#{ruby_content}': #{e.message}", e.backtrace
            end
            value
        end

        # Loads the configurations from a YAML file
        #
        # Multiple configurations can be saved in the file, in which case each
        # configuration set must be separated by a line of the form
        #
        #   --- name:configuration_name
        #
        # The first YAML document has, by default, the name 'default'. One can
        # also be provided if needed.
        #
        # @return [Array<String>] the names of the sections that have been modified
        def load_from_yaml(file)
            document_lines = File.readlines(file)

            headers = document_lines.enum_for(:each_with_index).
                find_all { |line, _| line =~ /^---/ }
            if headers.empty? || headers.first[1] != 0
                headers.unshift ["--- name:default", -1]
            end

            options = headers.map do |line, line_number|
                line_options = Hash.new
                line = line.chomp
                line.split(/\s+/)[1..-1].each do |opt|
                    if opt =~ /^(\w+):(.*)$/
                        line_options[$1] = $2
                    else
                        raise ArgumentError, "#{file}:#{line_number}: wrong format #{opt}, expected option_name:value, where 'value' has no spaces"
                    end
                end
                line_options['merge'] = (line_options['merge'] == 'true')
                line_options['chain'] = (line_options['chain'] || '').split(',')
                [line_options, line_number]
            end
            options[0][0]['name'] ||= 'default'

            options.each do |line_options, line_number|
                if !line_options['name']
                    raise ArgumentError, "#{file}:#{line_number}: missing a 'name' option"
                end
            end

            sections = []
            options.each_cons(2) do |(_, line0), (_, line1)|
                sections << document_lines[line0 + 1, line1 - line0 - 1]
            end
            sections << document_lines[options[-1][1] + 1, document_lines.size - options[-1][1] - 1]

            changed_sections = []
            @conf_options = options

            sections.each_with_index do |doc, idx|
                doc = doc.join("")
                doc = evaluate_dynamic_content(file, doc)

                result = YAML.load(StringIO.new(doc))

                conf_options = options[idx].first
                name = conf_options.delete('name')
                if add(name, result || Hash.new, conf_options)
                    changed_sections << name
                end
            end
	    if !changed_sections.empty?
	    	@merged_conf.clear
	    end
            changed_sections
        rescue Exception => e
            raise e, "error loading #{file}: #{e.message}", e.backtrace
        end

        # Add a new configuration section to the configuration set
        #
        # @param [String] name the configuration section name
        # @param [Object] conf the configuration data. See {#sections} for a
        #   description of its formatting
        # @param [Hash] options the options of this configuration section
        def add(name, conf, options = Hash.new)
            options = Kernel.validate_options options,
                :merge => true, :chain => nil

            conf = config_from_hash(conf)

            changed = false
            if self.sections[name]
                if options[:merge]
                    conf = TaskConfigurations.merge_conf(self.sections[name], conf, true)
                end
                changed = changed || self.sections[name] != conf
            else
                changed = true
            end
            self.sections[name] = conf
            changed
        end

        # Converts an array to a properly formatted configuration value
        #
        # See {#sections} for a description of configuration value formatting
        #
        # @param [Array] array the input array
        # @param [Model<Typelib::Type>] value_t the description of the expected type
        # @return [Object] a properly formatted configuration value based on the
        #   input array
        def config_from_array(array, value_t)
            element_t = value_t.deference
            array.map do |value|
                if value.kind_of?(Hash)
                    config_from_hash(value, element_t)
                elsif value.respond_to?(:to_ary)
                    config_from_array(value, element_t)
                else
                    Typelib.from_ruby(value, element_t)
                end
            end
        end

        # Converts a hash to a properly formatted configuration value
        #
        # See {#sections} for a description of configuration value formatting
        #
        # @param [Hash] hash the input hash
        # @param [Model<Typelib::Compound>,nil] base the description of the
        #   expected type. If nil, the function will assume that the hash keys
        #   are propery names and the types will be taken from {#model}
        # @return [Object] a properly formatted configuration value based on the
        #   input hash
        def config_from_hash(hash, base = nil) # :nodoc:
            result = Hash.new
            hash.each do |key, value|
                if base
                    value_t = base[key]
                else
                    prop = model.find_property(key)
                    if !prop
                        raise ArgumentError, "#{key} is not a property of #{model.name}"
                    end
                    value_t = Orocos.typelib_type_for(prop.type)
                end

                value =
                    if value.kind_of?(Hash)
                        config_from_hash(value, value_t)
                    elsif value.respond_to?(:to_ary)
                        config_from_array(value, value_t)
                    else
			begin
			    Typelib.from_ruby(value, value_t)
			rescue Exception => e 
			    raise ArgumentError, "could not convert value for #{key}. #{e}"
			end
                    end

                result[key] = value
            end
            result
        end

        def self.merge_conf_array(a, b, override)
            result = []
            a.each_with_index do |v1, idx|
                v2 = b[idx]

                if !v2
                    result << v1
                    next
                elsif !v1
                    result << v2
                    next
                end

                if v1.kind_of?(Hash) && v2.kind_of?(Hash)
                    result << merge_conf(v1, v2, override)
                elsif v1.respond_to?(:to_ary) && v2.respond_to?(:to_ary)
                    result << merge_conf_array(v1, v2, override)
                elsif override || v1 == v2
                    result << v2
                else
                    raise ArgumentError, "cannot merge configuration: conflict in [#{idx}] between v1=#{v1} and v2=#{v2}"
                end
            end

            if b.size > a.size
                result.concat(b[a.size..-1])
            end
            result
        end

        # Helper method that adds the configuration of +b+ into the existing
        # configuration hash +a+
        #
        # See {#sections} for a description of how the configuration value
        # formatting allows this to be done.
        def self.merge_conf(a, b, override)
            result = if override
                a.recursive_merge(b) do |k, v1, v2|
                    if v1.respond_to?(:to_ary) && v2.respond_to?(:to_ary)
                        merge_conf_array(v1, v2, true)
                    else
                        v2
                    end
                end
            else
                a.recursive_merge(b) do |k, v1, v2|
                    if v1.respond_to?(:to_ary) && v2.respond_to?(:to_ary)
                        merge_conf_array(v1, v2, false)
                    elsif v1 != v2
                        raise ArgumentError, "cannot merge configuration: conflict in field #{k} between v1=#{v1} and v2=#{v2}"
                    else
                        v1
                    end
                end
            end
            result
        end

        # Returns the task configuration that is the combination of the
        # named configuration sections
        #
        # @param [Array<String>] names the list of sections that should be applied
        # @param [Boolean] override if false, one of the sections listed in the
        #   names parameter cannot override the value set by another. Otherwise,
        #   the configurations are merged, with the sections appearing last
        #   overriding the sections appearing first.
        # @raise ArgumentError if one of the listed sections does not exist, or
        #   if the override option is false and two sections try to set the same
        #   property
        # @return [Hash] a hash in which the keys are property names and the
        #   values Typelib values that can be used to set these properties. See
        #   {#apply} for a shortcut to apply a configuration on a task
        #
        # For instance, let's assume that the following configurations are
        # available
        #
        #   --- name:default
        #   threshold: 20
        #   --- name: fast
        #   speed: 10
        #   --- name: slow
        #   speed: 1
        #
        # Then
        # 
        #   configuration(['default', 'fast'])
        #
        # returns { 'threshold' => 20, 'speed' => 10 } regardless of the value
        # of the override parameter, while
        # 
        #   configuration(['default', 'fast', 'slow'])
        #
        # will raise ArgumentError and 
        # 
        #   configuration(['default', 'fast', 'slow'], true)
        #
        # returns { 'threshold' => 20, 'speed' => 1 }
        def conf(names, override = false)
            if names.size == 1
                return sections[names.first]
            elsif cached = @merged_conf[[names, override]]
                return cached
            else
                if !sections[names.last]
                    raise ArgumentError, "#{names.last} is not a known configuration section"
                end
                config = conf(names[0..-2], override)
                config = TaskConfigurations.merge_conf(config, sections[names.last], override)

                @merged_conf[[names, override]] = config
                return config
            end
        end

        # Applies the specified configuration to the given task
        #
        # @param [TaskContext] task the task on which the configuration should
        #   be applied
        # @param (see #conf)
        # @raise (see #conf)
        #
        # See {#conf} for additional examples
        def apply(task, names, override = false)
            if names.respond_to?(:to_ary)
                config = conf(names, override)
            elsif names.respond_to?(:to_str)
                config = conf([names], override)
            else
                config = names
            end

            if !config
                if names == ['default']
                    ConfigurationManager.info "required to apply configuration #{names.join(", ")} on #{task.name} of type #{task.model.name}, but this configuration is not registered or empty. Not changing anything."
                    return
                else
                    raise ArgumentError, "no configuration #{names.join(", ")} for #{task.model.name}"
                end
            end
            
            timestamp = Time.now
            config.each do |prop_name, conf|
                p = task.property(prop_name)
                result = p.raw_read
                result = TaskConfigurations.typelib_from_yaml_value(result, conf)
                p.write(result, timestamp)
            end
        end

        # Helper method for {.typelib_from_yaml_value} when the YAML value is a
        # hash
        def self.typelib_from_yaml_hash(value, conf)
            conf.each do |conf_key, conf_value|
                value.raw_set(conf_key, typelib_from_yaml_value(value.raw_get(conf_key), conf_value))
            end
            value
        end

        # Helper method for {.typelib_from_yaml_value} when the YAML value is an
        # array
        def self.typelib_from_yaml_array(value, conf)
            if value.kind_of?(Typelib::ArrayType)
                # This is a fixed-size array, verify that the size matches
                if conf.size > value.size
                    raise ArgumentError, "Configuration object size is larger than field #{value}"
                end
            else
                while value.size < conf.size
                    new_value = value.class.deference.new
                    new_value.zero!
                    value.push(new_value)
                end
            end
            conf.each_with_index do |element, idx|
                value[idx] = typelib_from_yaml_value(value.raw_get(idx), element)
            end
            value
        end

        # Applies a value coming from a YAML-compatible data structure to a
        # typelib value
        #
        # @param [Typelib::Type] value the value to be updated. Note that the
        #   actually updated value is returned by the method (it might be
        #   different)
        # @param [Object] conf a straight YAML object (i.e. an object that is
        #   made only of data that is part of the YAML representation). It is
        #   usually generated by {.typelib_to_yaml_value}
        # @return [Typelib::Type] the updated value. It is not necessarily equal
        #   to value
        def self.typelib_from_yaml_value(value, conf)
            if conf.kind_of?(Hash)
                typelib_from_yaml_hash(value, conf)
            elsif conf.respond_to?(:to_ary)
                typelib_from_yaml_array(value, conf)
            else
                Typelib.from_ruby(conf, value.class)
            end
        end

        # Converts a typelib value into an object that can be represented
        # straight in YAML
        #
        # The inverse operation can be performed by {.typelib_from_yaml_value}
        #
        # @param [Typelib::Type] value the value to be converted
        # @return [Object] a value that can be represented in YAML as-is
        def self.typelib_to_yaml_value(value)
            if value.kind_of?(Typelib::CompoundType)
                result = Hash.new
                value.raw_each_field do |field_name, field_value|
                    result[field_name] = typelib_to_yaml_value(field_value)
                end
                result
            elsif value.kind_of?(Symbol)
                value.to_s
            elsif value.respond_to?(:to_str)
                value.to_str
            elsif value.kind_of?(Typelib::ArrayType) || value.kind_of?(Typelib::ContainerType)
                value.raw_each.map(&method(:typelib_to_yaml_value))
            elsif value.kind_of?(Typelib::Type)
                Typelib.to_ruby(value)
            else value
            end
        end

        # Converts the properties of a task into a hash that can be represented
        # in YAML
        #
        # @param [#each_property] task the task. The yield properties have to
        #   respond to raw_read
        # @return [Hash] the converted data
        def self.config_as_hash(task)
            current_config = Hash.new
            task.each_property do |prop|
                # Make sure we dont extract metadata information, check here against the
                # typename instead aainst the type, to prevent problem if the
                # metadata support is not installed.
                if prop.name == "metadata" and prop.orocos_type_name == "/metadata/Component"
                    next 
                end
                current_config[prop.name] = typelib_to_yaml_value(prop.raw_read)
            end
            current_config
        end

        # Saves the current configuration of task in a file and updates the
        # section in this object
        #
        # @param (see TaskConfigurations.save)
        # @return (see TaskConfigurations.save)
        def save(task, file, name)
            config_hash = self.class.save(task, file, name)
            sections[name] = config_from_hash(config_hash)
        end

        # Saves the current configuration of task in a file
        #
        # @param [TaskContext] task the task whose configuration is to be saved
        # @param [String] file either a file or a directory. If it is a
        #   directory, the generated file will be named based on the task's
        #   model name
        # @param [String,nil] name the name of the new section. If nil is given,
        #   defaults to task.name 
        # @return [Hash] the task configuration in YAML representation, as
        #   returned by {.config_as_hash}
        # @see TaskConfigurations#save
        def self.save(task, file, name)
            if File.directory?(file)
                file = File.join(file, "#{task.model.name}.yml")
            else
                FileUtils.mkdir_p(File.dirname(file))
            end
            name ||= task.name

            current_config = config_as_hash(task)

            parts = []
            current_config.keys.sort.each do |property_name|
                doc = task.model.find_property(property_name).doc
                if doc
                    parts << doc.split("\n").map { |s| "# #{s}" }.join("\n")
                else
                    parts << "# no documentation available for this property"
                end

                property_hash = { property_name => current_config[property_name] }
                yaml = YAML.dump(property_hash)
                parts << yaml.split("\n")[1..-1].join("\n")
            end

            File.open(file, 'a') do |io|
                io.write("--- name:#{name}\n")
                io.write(parts.join("\n"))
                io.puts
            end
            current_config
        end
    end

    # @deprecated use Orocos.apply_conf instead
    def self.apply_conf_file(task, path, names = ['default'], overrides = true)
        conf = TaskConfigurations.new(task.model)
        conf.load_from_yaml(path)
        conf.apply(task, names, overrides)
        task
    end

    # Applies the configuration stored in +path+ on +task+. The selected
    # sections can be listed in +names+ (by default, uses the default
    # configuration).
    #
    # +overrides+ controls whether the sections listed in +names+ can override
    # each other, if a value set in one of them can be overriden by another one.
    #
    # +path+ can either be a file or a directory. In the latter case, the
    # configuration stored in path/model_name.yml will be used
    def self.apply_conf(task, path, names = ['default'], overrides = true)
        if File.directory?(path)
            path = File.join(path, "#{task.model.name}.yml")
            if !File.file?(path)
                return
            end
        end

        conf = TaskConfigurations.new(task.model)
        conf.load_from_yaml(path)
        conf.apply(task, names, overrides)
        task
    end

    # Class that manages a set of configurations
    class ConfigurationManager
        extend Logger::Forward
        extend Logger::Hierarchy

        # A mapping from the task model names to the corresponding
        # {TaskConfigurations} object
        #
        # @return [{String=>TaskConfigurations}]
        attr_reader :conf

        def initialize
            @conf = Hash.new
        end

        # Loads all configuration files present in the given directory
        #
        # The directory is assumed to be populated with files of the form
        #
        #   orogen_project::TaskName.yml
        #
        # each file being a YAML file that follows the format described in
        # the documentation of {TaskConfigurations}. It will ignore files that
        # do not match this pattern, as well as file that refer to task models
        # that cannot be found.
        #
        # @param [String] dir the path to the directory
        # @return [{String=>Array<String>}] a mapping from the task model
        #   name to the list of configuration sections that got modified or added.
        #   Note that the set of sections is guaranteed to not be empty
        def load_dir(dir)
            if !File.directory?(dir)
                raise ArgumentError, "#{dir} is not a directory"
            end

            changed = Hash.new
            Dir.glob(File.join(dir, '*.yml')) do |file|
                next if !File.file?(file)

                changed_configurations =
                    begin load_file(file)
                    rescue Orocos::NotFound
                        ConfigurationManager.warn "ignoring configuration file #{file} as there are no corresponding task model"
                        next
                    end

                if changed_configurations
                    changed.merge!(changed_configurations) do |model_name, old, new|
                        old.concat(new).uniq
                    end

                    changed_configurations.each do |model_name, conf|
                        ConfigurationManager.info "  configuration #{conf} of #{model_name} changed"
                    end
                end
            end
            changed
        end

        # Loads configuration from a YAML file
        #
        # @param [String] file the path to the file
        # @param [String,OroGen::Spec] model it is either an oroGen task context
        #   model or the name of such a model If nil, the model is inferred from
        #   the file name, which is expected to be of the form
        #   orogen_project::TaskName.yml
        # @return [{String=>Array<String>},nil] if some configuration sections
        #   changed or got added, the method returns a mapping from the task model
        #   name to the list of modified sections. Otherwise, it returns false
        # @raise ArgumentError if the file does not exist
        # @raise OroGen::TaskModelNotFound if the task model cannot be found
        def load_file(file, model = nil)
            if !File.file?(file)
                raise ArgumentError, "#{file} does not exist or is not a file"
            end

            if !model || model.respond_to?(:to_str)
                model_name = model || File.basename(file, '.yml')
                begin
                    model = Orocos.default_loader.task_model_from_name(model_name)
                rescue OroGen::TaskModelNotFound
                    ConfigurationManager.warn "ignoring configuration file #{file} as there are no corresponding task model"
                    return false
                end
            end

            ConfigurationManager.info "loading configuration file #{file} for #{model.name}"
            conf[model.name] ||= TaskConfigurations.new(model)

            changed_configurations = conf[model.name].load_from_yaml(file)
            ConfigurationManager.info "  #{model.name} available configurations: #{conf[model.name].sections.keys.join(", ")}"
            if changed_configurations.empty?
                return false
            else
                Hash[model.name => changed_configurations]
            end
        end

        def find_task_configuration_object(task, options = Hash.new)
            if !task.model
                raise ArgumentError, "cannot use ConfigurationManager#apply for non-orogen tasks"
            end
            options = Kernel.validate_options options, :model_name => task.model.name
            conf[options[:model_name]]
        end

        # Applies the specified configuration on +task+
        #
        # @param task (see TaskConfigurations#apply)
        # @param names (see TaskConfigurations#apply)
        # @option options [String] :model_name (task.model.name) the name of the
        #   model that should be used to resolve the configurations
        # @option options [Boolean] :override (false) see the documentation of
        #   {TaskConfigurations#apply}
        # @raise (see TaskConfigurations#apply)
        def apply(task, names=Array.new, options = Hash.new)
            if options == true || options == false
                # Backward compatibility
                options = Hash[:override => options]
            end
            options, find_options = Kernel.filter_options options, :override => false, :model_name => task.model.name

            model_name = options[:model_name]
            task_conf = find_task_configuration_object(task, find_options.merge(:model_name => model_name))
            if names = resolve_requested_configuration_names(model_name, task_conf, names)
                ConfigurationManager.info "applying configuration #{names.join(", ")} on #{task.name} of type #{model_name}"
                task_conf.apply(task, names, options[:override])
            else
                ConfigurationManager.info "required default configuration on #{task.name} of type #{model_name}, but #{model_name} has no registered configurations"
            end
            true
        end

        def resolve_requested_configuration_names(model_name, task_conf, names)
            if !task_conf
                if names == ['default'] || names == []
                    return
                else
                    raise ArgumentError, "no configuration available for #{model_name}"
                end
            end
            
            # If no names are given try to figure them out 
            if !names || names.empty?
                if(task_conf.sections.size == 1)
                    [task_conf.sections.keys.first]
                else
                    ["default"]
                end
            else names
            end
        end

        # Saves the configuration for a task and dumps it to a YAML file
        #
        # This method adds the current configuration of the given task to the
        # existing configuration(s) for the task's model, and saves all of them
        # in a YAML file.
        #
        # @param [TaskContext] task the task whose configuration should be saved
        # @param [String] path the file or directory it should be saved to.
        #   If it is a directory, the configuration is saved in a file whose name
        #   is based on the task's model name (project_name::TaskName.yml).
        #   Otherwise, it is saved in the file. The directories leading to the
        #   file must exist.
        # @option options :model (task.model) the oroGen model used to dump the
        #   configuration
        # @option options :name (task.name) the name of the section that should
        #   be created
        #
        # @overload save(task, path, name)
        #   @deprecated old signature. One should use the option hash now.
        def save(task, path, options = Hash.new)
            if options.respond_to?(:to_str) || !options # for backward compatibility
                options = Hash[:name => options]
            end
            options, find_options = Kernel.filter_options options,
                :name => nil,
                :model => task.model

            model_name = options[:model].name
            task_conf = find_task_configuration_object(task, find_options.merge(:model_name => model_name))
            if !task_conf
                task_conf = conf[model_name] = TaskConfigurations.new(options[:model])
            end
            task_conf.save(task, path, options[:name])
        end

        # Returns a resolved configuration value for a task model name
        #
        # @param [String] task_model_name the name of the task model
        # @param [Array<String>] conf_names the name of the configuration
        #   sections
        # @param [Boolean] override if true, values that are set by early
        #   elements in conf_names will be overriden if set in later elements.
        #   Otherwise, ArgumentError is thrown when this happens.
        # @return [Object] a configuration object as formatted by the rules
        #   described in the {TaskConfigurations#sections} attribute description
        def resolve(task_model_name, conf_names = Array.new, override = false)
            if task_model_name.respond_to?(:model)
                task_model_name = task_model_name.model.name
            end
            task_conf = conf[task_model_name]
            if conf_names = resolve_requested_configuration_names(task_model_name, task_conf, conf_names)
                task_conf.conf(conf_names, override)
            else Hash.new
            end
        end
    end
end


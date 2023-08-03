require 'stringio'
require 'yaml'
require 'utilrb/hash/map_key'
require 'digest'

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
        # Exception raised when the user asks for a non-existent configuration
        class SectionNotFound < ArgumentError
            attr_reader :section_name

            def initialize(section_name)
                @section_name = section_name
            end
        end

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

        # @return [OroGen::Spec::TaskContext] the task context model for which self holds
        #   configurations
        attr_reader :model

        # @return [OroGen::Loaders::Base] a loader object that allows to access
        #   the underlying oroGen models
        def loader
            model.loader
        end

        def initialize(task_model)
            @model = task_model
            @sections = Hash['default' => Hash.new]
            @merged_conf = Hash.new
            @context = Array.new
        end

        def initialize_copy(source)
            super
            @sections = sections.map_value { |k, v| v.dup }
            @merged_conf = Hash.new
            @context = Array.new
        end

        # Retrieves the configuration for the given section name
        #
        # @return [Object] see the description of {#sections} for the description
        #   of formatting
        def [](section_name)
            sections[section_name]
        end

        # @api private
        #
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

        # Parses a configuration file to return the text of each section along
        # with the section's options
        #
        # @param [String] file the file
        # @return [Array<(Hash,String)>] the list of sections. The hash is the
        #   parsed representation of the option line (the line starting with
        #   ---) and the string is the raw section text
        def self.load_raw_sections_from_file(file)
            document_lines = File.readlines(file)

            headers =
                document_lines
                .each_with_index
                .find_all { |line, _| line =~ /^---/ }

            if headers.empty?
                headers.unshift ["--- name:default", -1]
            elsif headers.first[1] != 0
                leading_lines = document_lines[0, headers.first[1]].map(&:strip)
                if leading_lines.any? { |l| !l.empty? && !l.start_with?("#") }
                    headers.unshift ["--- name:default", -1]
                end
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

                section_options = Hash[
                    name: line_options.delete('name'),
                    merge: (line_options.delete('merge') == 'true'),
                    chain: (line_options.delete('chain') || '').split(',')]
                if !line_options.empty?
                    ConfigurationManager.warn "unrecognized options #{line_options.keys.sort.join(", ")} in #{file}"
                end

                [section_options, line_number]
            end
            options[0][0][:name] ||= 'default'

            options.each do |line_options, line_number|
                if !line_options[:name]
                    raise ArgumentError, "#{file}:#{line_number}: missing a 'name' option"
                end
            end

            sections = []
            options.each_cons(2) do |(_, line0), (_, line1)|
                sections << document_lines[line0 + 1, line1 - line0 - 1]
            end
            sections << document_lines[options[-1][1] + 1, document_lines.size - options[-1][1] - 1]

            sections = options.map(&:first).zip(sections)
            found_sections = []
            sections.each do |conf_options, doc|
                name = conf_options[:name]
                if found_sections.include?(name)
                    raise ArgumentError, "#{name} defined twice"
                end
                found_sections << name
            end
            sections
        end

        # @api private
        #
        # Read the YAML from the cache directory, if available
        def read_yaml_from_cache(cache_dir, doc)
            cache_id = Digest::SHA256.hexdigest(doc)
            path = File.join(cache_dir, cache_id)
            return cache_id unless File.exist?(path)

            begin
                [cache_id, Marshal.load(File.read(path))]
            rescue Exception
                cache_id
            end
        end

        # @api private
        #
        # Write the YAML to the cache directory, if available
        def save_yaml_to_cache(cache_dir, cache_id, contents)
            path = File.join(cache_dir, cache_id)
            File.open(path, 'w') do |io|
                io.write Marshal.dump(contents)
            end
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
        def load_from_yaml(file, cache_dir: nil)
            sections = self.class.load_raw_sections_from_file(file)

            changed_sections = []
            sections.each do |conf_options, doc|
                doc = doc.join("")
                doc = evaluate_dynamic_content(file, doc)

                if cache_dir
                    cache_id, cached_yaml = read_yaml_from_cache(cache_dir, doc)
                end
                unless cached_yaml
                    loaded_yaml = YAML.load(StringIO.new(doc)) || Hash.new
                end

                begin
                    result = normalize_conf(cached_yaml || loaded_yaml || Hash.new)
                rescue ConversionFailed => e
                    raise e, "while loading section #{conf_options[:name] || 'default'} #{e.message}", e.backtrace
                end

                if cache_id && !cached_yaml
                    save_yaml_to_cache(cache_dir, cache_id, loaded_yaml)
                end

                name  = conf_options.delete(:name)
                chain = conf(conf_options.delete(:chain), true)
                result = Orocos::TaskConfigurations.merge_conf(result, chain, true)
                changed = in_context("while loading section #{name} of #{file}") do
                    add(name, result, normalize: false, **conf_options)
                end

                if changed
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

        UNITS = Hash[
            'm' => 1,
            'N' => 1,
            'deg' => Math::PI / 180,
            's' => 1,
            'g' => 1e-3,
            'Pa' => 1,
            'bar' => 100_000]
        SCALES = Hash[
            'M' => 1e6,
            'k' => 1e3,
            'd' => 1e-1,
            'c' => 1e-2,
            'm' => 1e-3,
            'mu' => 1e-6,
            'n' => 1e-9,
            'p' => 1e-12]

        def self.convert_unit_to_SI(expr)
            unit, power = expr.split('^')
            power = Integer(power || '1')
            if unit_to_si = UNITS[unit]
                return unit_to_si ** power
            end

            SCALES.each do |prefix, scale|
                if unit.start_with?(prefix)
                    if unit_to_si = UNITS[unit[prefix.size..-1]]
                        return (unit_to_si*scale) ** power
                    end
                end
            end
            raise ArgumentError, "does not know how to convert #{expr} to SI"
        end

        ROUNDING_MODES = ['ceil', 'floor', 'round']

        def evaluate_numeric_field(field, field_type)
            rounding_mode = nil
            if field.respond_to?(:to_str)
                # Extract the value first
                if field =~ /^([+-]?\d+)$/
                    # This is a plain integer, don't bother and don't annoy the
                    # user with a float-to-integer rounding mode warning
                    return Integer(field)
                elsif field =~ /^([+-]?\d+(?:\.\d+)?(?:e[+-]\d+)?)(.*)/
                    value, unit = Float($1), $2
                else
                    raise ArgumentError, "#{field} does not look like a numeric field"
                end

                unit = unit.scan(/\.\w+(?:\^-?\d+)?/).inject(1) do |u, unit_expr|
                    unit_name = unit_expr[1..-1]
                    if ROUNDING_MODES.include?(unit_name)
                        rounding_mode = unit_name
                        u
                    else
                        u * TaskConfigurations.convert_unit_to_SI(unit_name)
                    end
                end
                value = value * unit
            else
                value = field
            end

            if value.kind_of?(Float) && field_type.integer?
                if !rounding_mode
                    ConfigurationManager.warn "#{current_context} #{field} used for an integer field, but no rounding mode specified. Append one of .round, .floor or .ceil. This defaults to .floor"
                    rounding_mode = :floor
                end
                value.send(rounding_mode)
            else value
            end
        end

        # Add a new configuration section to the configuration set
        #
        # @param [String] name the configuration section name
        # @param [{String=>Object}] conf the configuration data, as either a
        #   mapping from property names to property values, or property names to
        #   plain Ruby objects. It gets passed to {#normalize_conf}.
        # @param [Boolean] normalize if true, the configuration is normalized
        #   to this class' expected internal representation first. Set to
        #   false when the data has already been normalized.
        # @param [Boolean] merge if true, the configuration will be merged with
        #   an existing section that has the same name (if there is one)
        # @return [Boolean] true if the configuration changed, and false
        #   otherwise
        # @see extract
        def add(name, conf, normalize: true, merge: true)
            if normalize
                conf = normalize_conf(conf)
            end

            changed = false
            if self.sections[name]
                if merge
                    conf = TaskConfigurations.merge_conf(self.sections[name], conf, true)
                end
                changed = (self.sections[name] != conf)
                if changed
                    # This happens rarely, be brutal about cache invalidation
                    @merged_conf.clear
                end
            else
                changed = true
            end
            self.sections[name] = conf
            changed
        end

        # Remove a configuration section
        #
        # @param [String] name the section name
        # @return [Boolean] true if such as section existed, and false otherwise
        def remove(name)
            !!sections.delete(name)
        end

        # Extract configuration from a task object and save it as a section in self
        #
        # @param [#each_property] task the task. #each_property must yield
        #   objects which respond to #raw_read, this method returning a Typelib
        #   value.
        # @param [String] section_name the section name. If one already exists
        #   with that name it is overriden
        # @param [Boolean] merge if true, the configuration will be merged with
        #   an existing section that has the same name (if there is one)
        # @return [Boolean] true if the configuration changed, and false
        #   otherwise
        # @see add
        def extract(name, task, merge: true)
            in_context("while saving section #{name} from task #{task.name}(#{task.model.name})") do
                add(name, TaskConfigurations.read_task_conf(task), merge: merge)
            end
        end


        # Exception raised when a field in a configuration field cannot be
        # converted to the requested path
        class ConversionFailed < ArgumentError
            # Path to the configuration parameter
            attr_reader :full_path
            # The original error
            attr_reader :original_error

            def initialize(original_error = nil)
                super()
                @original_error = original_error
                @full_path = Array.new
            end

            def original_message
                original_error.message if original_error
            end
        end

        # Converts a representation of a task configuration
        #
        # @param [{String=>Object}] conf a mapping from property name to value.
        #   See {#normalize_conf_value} for a description of the value's
        #   formatting
        # @return [Object] a normalized configuration hash
        def normalize_conf(conf)
            property_types = Hash.new
            conf.each do |k, v|
                if p = model.find_property(k)
                    property_types[k] = model.loader.typelib_type_for(p.type)
                else
                    raise ConversionFailed.new, "#{k} is not a property of #{model.name}"
                end
            end

            return normalize_conf_hash(conf, property_types)
        end

        # Converts a value into a normalized representation suitable to be
        # stored in self
        #
        # {TaskConfigurations} stores configuration as a combination of
        # hashes (for structs), arrays (for arrays and containers) and typelib
        # values.
        #
        # Hashes and arrays are used to represent partial values. When applying
        # the configuration, they are applied to the existing objects without
        # erasing other existing data (e.g. with a hash, only the fields whose
        # keys are present will be applied to the value).
        #
        # Typelib values are final, i.e. they erase the complete part of the
        # configuration they represent
        #
        # This method iterates over the existing value, validates field names
        # and types, and converts leaves (e.g. numeric fields) to their typelib
        # representations once and for all.
        #
        # @param [Object] value a value that is a mix of hash, arrays and
        #   either nuermic/string values or typelib values. See description
        #   above for more details.
        # @param [Typelib::Type] value_t the type we are validating against
        # @return [Object] a normalized configuration value
        def normalize_conf_value(value, value_t)
            if value_t.method_defined?(:to_str)
                return normalize_conf_terminal_value(value, value_t)
            elsif value.kind_of?(value_t)
                return value
            end

            case value
            when Typelib::ContainerType, Typelib::ArrayType
                element_t = value_t.deference
                value.raw_each.map { |v| normalize_conf_value(v, element_t) }
            when Typelib::CompoundType
                result = Hash.new
                value.raw_each_field do |field_name, field_value|
                    result[field_name] = normalize_conf_value(field_value, value_t[field_name])
                end
                result
            when Hash
                if value_t <= Typelib::CompoundType
                    normalize_conf_hash(value, value_t)
                else
                    raise ConversionFailed.new, "cannot interpret a hash as a #{value_t.name}"
                end
            when Array
                if value_t <= Typelib::ArrayType || value_t <= Typelib::ContainerType
                    normalize_conf_array(value, value_t)
                else
                    raise ConversionFailed.new, "cannot interpret an array as #{value_t.name}"
                end
            else
                normalize_conf_terminal_value(value, value_t)
            end
        end

        # @api private
        #
        # Helper for {#normalize_conf_value} to normalize values that are
        # terminal, i.e. that should be converted to a typelib value
        def normalize_conf_terminal_value(value, value_t)
            if value_t <= Typelib::NumericType
                ruby_value = Typelib.to_ruby(value)
                if ruby_value.respond_to?(:to_str)
                    converted_value = evaluate_numeric_field(ruby_value, value_t)
                else
                    converted_value = value
                end
                typelib_value = Typelib.from_ruby(converted_value, value_t)
            else
                typelib_value = Typelib.from_ruby(value, value_t)
            end

            if typelib_value.class != value.class
                return normalize_conf_value(typelib_value, value_t)
            else
                typelib_value
            end

        rescue ArgumentError => e
            raise ConversionFailed.new(e), e.message, e.backtrace
        end

        # @api private
        #
        # Helper for {.}. See it for details
        def normalize_conf_array(array, value_t)
            if value_t.respond_to?(:length) && value_t.length < array.size
                raise ConversionFailed.new, "array too big (got #{array.size} for a maximum of #{value_t.length}"
            end

            element_t = value_t.deference
            if element_t <= Typelib::NumericType
                # Try to pack the array. If it works, return it straight.
                # Otherwise, go through the slow path
                begin
                    packed_array = array.pack("#{element_t.pack_code}*")
                    if value_t.respond_to?(:length)
                        if value_t.length == array.size
                            return value_t.from_buffer(packed_array)
                        else
                            return array.map do |v|
                                normalize_conf_terminal_value(v, element_t)
                            end
                        end
                    else
                        return value_t.from_buffer([array.size].pack("Q") + packed_array)
                    end
                rescue TypeError
                end
            end

            array.each_with_index.map do |value, i|
                begin
                    normalize_conf_value(value, element_t)
                rescue ConversionFailed => e
                    e.full_path.unshift "[#{i}]"
                    raise e, "failed to convert configuration value for #{e.full_path.join("")}", e.backtrace
                end
            end
        end

        # @api private
        #
        # Helper for {.normalize_conf} and {.normalize_conf_value}. See it for details
        #
        # @param [Hash] hash a hash representing a configuration value (in which
        #   case the keys are field names), or the configuration of a whole task
        #   (in which case the keys are property names)
        # @param [#[]] value_t representation of the value's type. It will
        #   usually be a subclass of Typelib::CompoundType, or a
        #   property-name-to-type mapping.
        def normalize_conf_hash(hash, value_t) # :nodoc:
            result = Hash.new
            hash.each do |key, value|
                begin
                    field_t = value_t[key]
                rescue ArgumentError => e
                    raise ConversionFailed.new(e), e.message, e.backtrace
                end

                begin
                    result[key] = normalize_conf_value(value, field_t)
                rescue ConversionFailed => e
                    e.full_path.unshift ".#{key}"
                    raise e, "failed to convert configuration value for #{e.full_path.join("")}: #{e.original_message}", e.backtrace
                end
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

        # Tests whether the given section exists
        def has_section?(name)
            sections.has_key?(name)
        end

        def each_resolved_conf
            return enum_for(__method__) if !block_given?
            sections.each_key do |conf_name|
                yield(conf_name, conf([conf_name]))
            end
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
        #
        # @raises [SectionNotFound] if one of the required
        #   configuration sections do not exist
        def conf(names, override = false)
            names = Array(names)
            if names.empty?
                return Hash.new
            elsif cached = @merged_conf[[names, override]]
                return cached
            else
                config = names.inject(Hash.new) do |c, section_name|
                    section = sections[section_name]
                    if !section
                        raise SectionNotFound.new(section_name), "#{section_name} is not a known configuration section for #{model.name}"
                    end
                    TaskConfigurations.merge_conf(c, section, override)
                end
                @merged_conf[[names, override]] = config
                return config
            end
        end

        # Returns the required configuration in a property-to-ruby form
        #
        # The objects are equivalent to the ruby objects one would get by
        # enumerating a task's property
        #
        # @param [String,Array<String>] names the configurations to apply. See
        #   {#conf} for more details
        # @param [Boolean] override see {#conf}
        #
        # @see conf conf_to_typelib
        def conf_as_ruby(names, override: false)
            conf = conf_as_typelib(names, override: override)
            conf.map_value do |_, v|
                Typelib.to_ruby(v)
            end
        end

        # Returns the required configuration in a property-to-typelib form
        #
        # The typelib values are equivalent to the typelib objects one would get
        # by enumerating a task's property
        #
        # @param [String,Array<String>] names the configurations to apply. See
        #   {#conf} for more details
        # @param [Boolean] override see {#conf}
        #
        # @see conf conf_to_ruby
        def conf_as_typelib(names, override: false)
            return unless (c = conf(names, override))

            c.each_with_object({}) do |(property_name, ruby_value), result|
                orocos_type = model.find_property(property_name).type
                typelib_type = loader.typelib_type_for(orocos_type)

                typelib_value = typelib_type.zero
                result[property_name] = TaskConfigurations.apply_conf_on_typelib_value(
                    typelib_value, ruby_value
                )
            end
        end

        # Applies the specified configuration to the given task
        #
        # @param [TaskContext] task the task on which the configuration should
        #   be applied
        # @param [String,Array<String>,Hash] config either the name (or names) of
        #   configuration section(s) as should be passed to {#conf}, or directly
        #   a configuration value as a mapping from property names to
        #   configuration object
        # @param [Boolean] override the override argument of {#conf}
        # @return [void]
        def apply(task, config, override = false)
            if !config.kind_of?(Hash)
                config = conf(config, override)
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
                result = TaskConfigurations.apply_conf_on_typelib_value(result, conf)
                p.write(result, timestamp)
            end
        end

        # @api private
        #
        # Helper method for {.to_typelib} when the value is an array
        def self.apply_conf_array_on_typelib_value(value, conf)
            if value.kind_of?(Typelib::ArrayType)
                # This is a fixed-size array, verify that the size matches
                if conf.size > value.size
                    raise ArgumentError,
                          "Configuration object size is larger than field #{value}"
                end
            else
                element_t = value.class.deference
                while value.size < conf.size
                    new_value = element_t.zero
                    value.push(new_value)
                end
            end
            conf.each_with_index do |element, idx|
                value[idx] = apply_conf_on_typelib_value(value.raw_get(idx), element)
            end
            value
        end

        # Applies a value coming from a YAML-compatible data structure to a
        # typelib value
        #
        # @param [Typelib::Type] value the value to be updated. Note that the
        #   actually updated value is returned by the method (it might be
        #   a different object)
        # @param [Object] conf a configuration object, as a mix of Hash, Array,
        #   Numeric, String and Typelib values
        # @return [Typelib::Type] the updated value. It is not necessarily equal
        #   to value
        def self.apply_conf_on_typelib_value(value, conf)
            if conf.kind_of?(Hash)
                conf.each do |conf_key, conf_value|
                    value.raw_set(conf_key,
                        apply_conf_on_typelib_value(value.raw_get(conf_key), conf_value))
                end
                value
            elsif conf.respond_to?(:to_ary)
                apply_conf_array_on_typelib_value(value, conf)
            else
                Typelib.from_ruby(conf, value.class)
            end
        end

        # Converts a configuration structure into a representation suitable for
        # marshalling into YAML
        #
        # @param [Object] value the value to be converted, this is a mix of
        #   Hash, Array, numeric and string Ruby objects, and Typelib values
        # @return [Object] a value that can be represented in YAML as-is
        def self.to_yaml(value)
            case value
            when Typelib::CompoundType
                value.apply_changes_from_converted_types

                result = Hash.new
                value.raw_each_field do |field_name, field_value|
                    result[field_name] = to_yaml(field_value)
                end
                result
            when Typelib::ArrayType, Typelib::ContainerType
                value.apply_changes_from_converted_types
                if value.respond_to?(:to_str)
                    value.to_str
                else
                    value.raw_each.map(&method(:to_yaml))
                end
            when Typelib::Type
                value.apply_changes_from_converted_types
                Typelib.to_ruby(value)
            when Array
                value.map(&method(:to_yaml))
            when Hash
                value.map_value do |_, v|
                    to_yaml(v)
                end
            when Numeric, String, Symbol
                value
            else
                raise ArgumentError, "invalid object #{value} of type #{value.class} found while converting typelib values to their YAML representation"
            end
        end

        # @api private
        #
        # Reads the configuration of a task into a property-name-to-typelib
        # value form
        def self.read_task_conf(task)
            current_config = Hash.new
            task.each_property do |prop|
                current_config[prop.name] = prop.raw_read
            end
            current_config
        end

        # Specifies a string that describes in which context we are currently
        # loading, for the benefit of warning and error messages.
        #
        # @yield within this block, {#current_context} will return the message
        #   string
        #
        # @param [String] msg the context string
        # @return [Object] the block's return value
        def in_context(msg)
            @context << msg
            yield
        ensure
            @context.pop
        end

        # Returns a string that describes in which context we are currently
        # loading, for the benefit of warning and error messages
        #
        # @see in_context
        # @return [String] the current context, or an empty string if none has
        #   been specified with {#in_context}
        def current_context
            @context.last || ''
        end

        # Save a configuration section to disk
        #
        # @overload save(section_name, file, replace: false, task_model: self.model)
        #   @param [String] section_name the section name
        #   @param [String] file either a file, or a directory. In the latter
        #     case, the file will be #\\{conf_dir\}/#\\{model\.name\}.yml
        #   @return [Hash] the configuration section that just got saved
        #
        # @overload save(task, file, section_name)
        #   @deprecated use {#extract} and {#save} instead
        #
        def save(*args, task_model: self.model, replace: false)
            if !args.first.respond_to?(:to_str)
                Orocos.warn "save(task, file, name) is deprecated, use a combination of #extract and #save(name, file) instead"
                task, file, name = *args
                extract(name, task)
                return save(name, file, task_model: task.model)
            end

            section_name, file = *args
            conf = conf(section_name)
            self.class.save(conf, file, section_name, task_model: task_model, replace: replace)
            conf
        end

        # Saves a configuration section to a file
        #
        # @overload save(conf, file, name)
        #   @param [Hash] config the configuration section that should be saved,
        #     either as a hash of plain Ruby objects, or as a mapping from
        #     property names to typelib values
        #   @param [String] file either a file or a directory. If it is a
        #     directory, the generated file will be named based on the task's
        #     model name
        #   @param [String,nil] name the name of the new section
        #   @param [TaskContext] task_model if given, the property's
        #     documentation stored in this model are added before each property
        #   @return [Hash] the task configuration in YAML representation, as
        #     returned by {.config_as_hash}
        #
        # @overload save(task, file, name)
        #   @param [TaskContext] task the task whose configuration is to be saved
        #   @param [String] file either a file or a directory. If it is a
        #     directory, the generated file will be named based on the task's
        #     model name
        #   @param [String,nil] name the name of the new section. If nil is given,
        #     defaults to task.name
        #   @return [Hash] the task configuration in YAML representation, as
        #     returned by {.config_as_hash}
        def self.save(config, file, name, task_model: nil, replace: false)
            if config.respond_to?(:each_property)
                conf = TaskConfigurations.new(task_model || config.model)
                conf.extract(name, config)
                return conf.save(name, file)
            end

            task_model ||= OroGen::Spec::TaskContext.blank
            config = to_yaml(config)

            if File.directory?(file)
                if !task_model.name
                    raise ArgumentError, "#{file} is a directory and the given model has no name"
                end
                file = File.join(file, "#{task_model.name}.yml")
            else
                FileUtils.mkdir_p(File.dirname(file))
            end

            parts = []
            config.keys.sort.each do |property_name|
                if (p = task_model.find_property(property_name)) && (doc = p.doc)
                    parts << doc.split("\n").map { |s| "# #{s}" }.join("\n")
                else
                    parts << "# no documentation available for this property"
                end

                property_hash = { property_name => config[property_name] }
                yaml = YAML.dump(property_hash)
                parts << yaml.split("\n")[1..-1].join("\n")
            end

            if !replace
                File.open(file, 'a') do |io|
                    io.write("--- name:#{name}\n")
                    io.write(parts.join("\n"))
                    io.puts
                end
            else
                raw_sections =
                    begin load_raw_sections_from_file(file)
                    rescue Errno::ENOENT
                        Array.new
                    end

                raw_sections.delete_if { |options, _| options[:name] == name }
                raw_sections << [Hash[name: name], parts.map { |l| "#{l}\n" }]
                File.open(file, 'w') do |io|
                    raw_sections.each do |options, doc|
                        formatted_options = options.map do |k, v|
                            if v.respond_to?(:to_ary)
                                next if !v.empty?
                                v = v.join(",")
                            end
                            "#{k}:#{v}"
                        end.compact
                        io.puts "--- #{formatted_options.join(" ")}"
                        io.write doc.join("")
                        if doc.last != "\n"
                            io.puts
                        end
                    end
                end
            end
            config
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

        attr_reader :loader

        # A mapping from the task model names to the corresponding
        # {TaskConfigurations} object
        #
        # @return [{String=>TaskConfigurations}]
        attr_reader :conf

        def initialize(loader = Orocos.default_loader)
            @loader = loader
            @conf   = Hash.new
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
                    rescue OroGen::TaskModelNotFound
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
                model = loader.task_model_from_name(model_name)
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
            if model_name.nil?
                raise ArgumentError, "applying configuration on #{task.name} failed. #{task.class} has no model name."
            end
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
                    section_name = names.find { |n| n != 'default' }
                    raise TaskConfigurations::SectionNotFound.new(section_name), "no configuration available for #{model_name} (expected #{names.join(", ")})"
                end
            end

            # If no names are given try to figure them out
            if !names || names.empty?
                if(task_conf.sections.size == 1)
                    [task_conf.sections.keys.first]
                else
                    ["default"]
                end
            else Array(names)
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
            name = options[:name] || task.name
            task_conf.extract(name, task)
            task_conf.save(name, path, task_model: task.model)
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

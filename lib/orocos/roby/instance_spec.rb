module Orocos
    module RobyPlugin
        # Class that is used to represent a binding of a service model with an
        # actual task instance during the instanciation process
        class DataServiceInstance
            # The ProvidedDataService instance that represents the data service
            attr_reader :provided_service_model
            # The task instance we are bound to
            attr_reader :task

            def initialize(task, provided_service_model)
                @task, @provided_service_model = task, provided_service_model
                if !task.kind_of?(Component)
                    raise "expected a task instance, got #{task}"
                end
                if !provided_service_model.kind_of?(ProvidedDataService)
                    raise "expected a provided service, got #{provided_service_model}"
                end
            end

            def short_name
                "#{task}:#{provided_service_model.name}"
            end

	    def each_fullfilled_model(&block)
		provided_service_model.component_model.each_fullfilled_model(&block)
	    end

            def fullfills?(*args)
                provided_service_model.fullfills?(*args)
            end
        end

        # Generic representation of requirements on a component instance
        #
        # Components can be compositions, services and/or 
        #
        # It is used by compositions to represent the requirements on their
        # children (through the CompositionChildDefinition class) and by the
        # Engine to represent instanciation requirements as set by #add or
        # #define (through the EngineRequirement class)
        class InstanceRequirements
            # The component model narrowed down from +base_models+ using
            # +using_spec+
            attr_reader :models
            # The component model specified by #add
            attr_reader :base_models
            # Required arguments on the final task
            attr_reader :arguments
            # The model selection that can be used to instanciate this task
            attr_reader :selections

            # The model selection that can be used to instanciate this task,
            # as resolved using names and application of default selections
            #
            # This information is only valid in the instanciation context, i.e.
            # while the underlying engine is instanciating the requirements
            attr_reader :resolved_using_spec

            def initialize(models = [])
                @models    = @base_models = models
                @arguments = Hash.new
                @selections = DependencyInjection.new
            end

            def initialize_copy(old)
                @models = old.models.dup
                @base_models = old.base_models.dup
                @arguments = old.arguments.dup
                @selections = old.selections.dup
            end

            # Add new models to the set of required ones
            def add_models(new_models)
                new_models = new_models.dup
                new_models.delete_if { |m| @base_models.any? { |bm| bm.fullfills?(m) } }
                base_models.delete_if { |bm| new_models.any? { |m| m.fullfills?(bm) } }
                @base_models |= new_models.to_value_set
                narrow_model
            end

            # Return true if this child provides all of the required models
            def fullfills?(required_models)
                if !required_models.respond_to?(:each)
                    required_models = [required_models]
                end
                required_models.all? do |req_m|
                    models.any? { |m| m.fullfills?(req_m) }
                end
            end

            # Merges two lists of models into a single one.
            #
            # The resulting list can only have a single class object. Modules
            # that are already included in these classes get removed from the
            # list as well
            #
            # Raises if +a+ and +b+ contain two classes that can't be mixed.
            def self.merge_model_lists(a, b)
                a_classes, a_modules = a.partition { |k| k.kind_of?(Class) }
                b_classes, b_modules = b.partition { |k| k.kind_of?(Class) }

                klass = a_classes.first || b_classes.first
                a_classes.concat(b_classes).each do |k|
                    if k < klass
                        klass = k
                    elsif !(klass <= k)
                        raise ArgumentError, "cannot merge #{a} and #{b}: classes #{k} and #{klass} are not compatible"
                    end
                end

                result = ValueSet.new
                result << klass if klass
                a_modules.concat(b_modules).each do |m|
                    do_include = true
                    result.delete_if do |other_m|
                        do_include &&= !(other_m <= m)
                        m < other_m
                    end
                    if do_include
                        result << m
                    end
                end
                result
            end

            # Merges +self+ and +other_spec+ into +self+
            #
            # Throws ArgumentError if the two specifications are not compatible
            # (i.e. can't be merged)
            def merge(other_spec)
                @base_models = InstanceRequirements.merge_model_lists(@base_models, other_spec.base_models)
                @arguments = @arguments.merge(other_spec.arguments) do |name, v1, v2|
                    if v1 != v2
                        raise ArgumentError, "cannot merge #{self} and #{other_spec}: argument value mismatch for #{name}, resp. #{v1} and #{v2}"
                    end
                    v1
                end
                @selections.merge(other_spec.selections)

                # Call modules that could have been included in the class to
                # extend it
                super if defined? super

                narrow_model
            end

            def hash; base_models.hash end
            def eql?(obj)
                obj.kind_of?(InstanceRequirements) &&
                    obj.selections == selections &&
                    obj.arguments == arguments &&
                    (super if defined? super)
            end
            def ==(obj)
                eql?(obj)
            end

            ##
            # :call-seq:
            #   use 'child_name' => 'component_model_or_device'
            #   use 'child_name' => ComponentModel
            #   use ChildModel => 'component_model_or_device'
            #   use ChildModel => ComponentModel
            #   use Model1, Model2, Model3
            #
            # Provides explicit selections for the children of compositions
            #
            # In the first two forms, provides an explicit selection for a
            # given child. The selection can be given either by name (name
            # of the model and/or of the selected device), or by directly
            # giving the model object.
            #
            # In the second two forms, provides an explicit selection for
            # any children that provide the given model. For instance,
            #
            #   use IMU => XsensImu::Task
            #
            # will select XsensImu::Task for any child that provides IMU
            #
            # Finally, the third form allows to specify preferences without
            # being specific about where to put them. If ambiguities are
            # found, and if only one of the possibility is listed there,
            # then that possibility will be selected. It has a lower
            # priority than the explicit selection.
            #
            # See also Composition#instanciate
            def use(*mappings)
                Engine.debug "adding use mappings #{mappings} to #{self}"

                composition_model = base_models.find { |m| m <= Composition }
                if !composition_model
                    raise ArgumentError, "#use is available only for compositions, got #{base_models.map(&:short_name).join(", ")}"
                end

                explicit, defaults = DependencyInjection.validate_use_argument(*mappings)
                selections.add_explicit(explicit)
                selections.add_defaults(defaults)

                narrow_model
                self
            end

            # Specifies new arguments that must be set to the instanciated task
            def with_arguments(arguments)
                @arguments.merge!(arguments)
                self
            end

            # Specifies that the task that is represented by this requirement
            # should use the given configuration
            def use_conf(*conf)
                @arguments[:conf] = conf
                self
            end

            # Add a new model in the base_models set, and update +models+
            # accordingly
            #
            # This method will keep the base_models consistent: +model+ is added
            # only if it is not yet provided in base_models, and any model in
            # +base_models+ that is also provided by +model+ will be removed.
            #
            # Returns true if +model+ did add a new constraint to the
            # specification, and false otherwise
            def require_model(model)
                if !model.kind_of?(Module) || !model.kind_of?(Class)
                    raise ArgumentError, "expected module or class, got #{model}"
                end
                need_model = true
                base_models.delete_if do |m|
                    if model < m
                        true
                    elsif m <= model
                        need_model = false
                        false
                    end
                end

                if need_model
                    base_models << model
                    narrow_model
                    return true
                else
                    return false
                end
            end

            # Computes the value of +model+ based on the current selection
            # (in #selections) and the base model specified in #add or
            # #define
            def narrow_model
                composition_model = base_models.find { |m| m <= Composition }
                if !composition_model
                    Engine.debug { "not narrowing as this selection is not a composition (models=#{base_models.map(&:name)})" }
                    @models = @base_models
                    return
                end

                Engine.debug do
                    Engine.debug "narrowing model"
                    Engine.debug "  from #{composition_model.short_name}"
                    break
                end

                selection = self.selections.dup
                selection.remove_unresolved
                candidates = Engine.log_nest(2) do
                    composition_model.narrow(DependencyInjectionContext.new(selection))
                end
                result =
                    if candidates.size == 1
                        candidates.find { true }
                    else
                        composition_model
                    end

                Engine.debug do
                    if candidates.size > 1
                        Engine.debug "  found multiple candidates, using default model #{result.short_name}"
                    else
                        Engine.debug "  using #{result.short_name}"
                    end
                    break
                end

                models = base_models.dup
                models.delete_if { |m| result.fullfills?(m) }
                models << result
                @models = models
                return result
            end

            attr_reader :required_host

            # Requires that this spec runs on the given process server, i.e.
            # that all the corresponding tasks are running on that process
            # server
            def on_server(name)
                @required_host = name
            end

            # Returns a task that can be used in the plan as a placeholder for
            # this instance
            def create_placeholder_task
                task_model = models.find { |m| m <= Roby::Task }
                if task_model
                    task = task_model.new(@arguments)
                else 
                    if !@task_model
                        @task_model = DataServiceModel.proxy_task_model(models)
                    end
                    task = @task_model.new(@arguments)
                end
                task.required_host = self.required_host
                task.abstract = true
                task
            end

            # Create a concrete task for this requirement
            def instanciate(engine, context, arguments = Hash.new)
                task_model = models.find { |m| m < Component }
                if !task_model
                    raise ArgumentError, "cannot call #instanciate on a composite model"
                end

                context.push(selections)

                arguments = Kernel.validate_options arguments, :task_arguments => nil
                instanciate_arguments = {
                    :as => name,
                    :task_arguments => self.arguments }
                if arguments[:task_arguments]
                    instanciate_arguments[:task_arguments].merge!(arguments[:task_arguments])
                end

                @task = task_model.instanciate(engine, context, instanciate_arguments)
                if !task_model.fullfills?(base_models)
                    raise InternalError, "instanciated task #{@task} does not provide the required models #{base_models.map(&:short_name).join(", ")}"
                end

                if required_host && task.respond_to?(:required_host=)
                    task.required_host = required_host
                end

                @task
            end

            # Resolves a selection given through the #use method
            #
            # It can take, as input, one of:
            # 
            # * an array, in which case it is called recursively on each of
            #   the array's elements.
            # * an EngineRequirement (returned by Engine#add)
            # * a name
            #
            # In the latter case, the name refers either to a device name,
            # or to the name given through the ':as' argument to Engine#add.
            # A particular service can also be selected by adding
            # ".service_name" to the component name.
            #
            # The returned value is either an array of resolved selections,
            # a Component instance or an InstanciatedDataService instance.
            def self.resolve_explicit_selection(value, engine)
                case value
                when DeviceInstance
                    if value.task
                        DataServiceInstance.new(value.task, value.service)
                    else
                        value.service
                    end
                        
                when EngineRequirement, ProvidedDataService, Roby::Task, CompositionChild
                    value
                when Class
                    if value <= Component
                        value
                    else
                        raise ArgumentError, "#{value} is not a valid explicit selection"
                    end
                when DataServiceInstance
                    return value
                else
                    if value.respond_to?(:to_ary)
                        value.map { |v| resolve_explicit_selection(v, engine) }
                    else
                        raise ArgumentError, "#{value} is not a valid explicit selection"
                    end
                end
            end

            def each_fullfilled_model(&block)
                models.each do |m|
                    m.each_fullfilled_model(&block)
                end
            end

            def as_plan
                Orocos::RobyPlugin::SingleRequirementTask.subplan(self)
            end

            def to_s
                if base_models.empty?
                    result = "#<#{self.class}: <no models>"
                else
                    result = "#<#{self.class}: models=#{models.map(&:short_name).join(",")} base=#{base_models.map(&:short_name).join(",")}"
                end
                if !selections.empty?
                    result << " using(#{selections})"
                end
                if !arguments.empty?
                    result << " args(#{arguments})"
                end
                result << ">"
            end

            def pretty_print(pp)
                pp.text "InstanceRequirements"
                if base_models.empty?
                    pp.breakable
                    pp.text "No models"
                else
                    pp.breakable
                    pp.text "Base Models:"
                    pp.nest(2) do
                        pp.breakable
                        pp.seplist(base_models) do |mod|
                            pp.text mod.short_name
                        end
                    end

                    pp.breakable
                    pp.text "Narrowed Models:"
                    pp.nest(2) do
                        pp.breakable
                        pp.seplist(models) do |mod|
                            pp.text mod.short_name
                        end
                    end
                end

                if !selections.empty?
                    pp.breakable
                    pp.text "Using:"
                    pp.nest(2) do
                        pp.breakable
                        selections.pretty_print(pp)
                    end
                end

                if !arguments.empty?
                    pp.breakable
                    pp.text "Arguments: #{selections}"
                end
            end
        end

        # Representation and manipulation of dependency injection selection
        class DependencyInjection
            attr_reader :explicit
            attr_reader :defaults

            def hash; [explicit, defaults].hash end
            def eql?(obj)
                obj.kind_of?(DependencyInjection) &&
                    explicit == obj.explicit &&
                    defaults == obj.defaults
            end
            def ==(obj); eql?(obj) end

            # creates a new DependencyInjection instance
            #
            # If arguments are provided, they must match the format expected by
            # #add
            def initialize(*base)
                @explicit = Hash.new
                @defaults = Set.new
                if !base.empty?
                    add(*base)
                end
            end

            # True if this object contains no selection at all
            def empty?
                @explicit.empty? && @defaults.empty?
            end

            def to_s # :nodoc:
                explicit = self.explicit.map { |k, v| [k.to_s, v.to_s] }.sort_by(&:first).map { |k, v| "#{k} => #{v}" }
                defaults = self.defaults.map(&:to_s)
                "#<DependencyInjection: #{defaults.concat(explicit).join(", ")}>"
            end

            def pretty_print(pp)
                pp.text "DependencyInjection"

                pp.breakable
                pp.text "Explicit:"
                if !explicit.empty?
                    pp.nest(2) do
                        pp.breakable
                        explicit = self.explicit.map { |k, v| [k.to_s, "#{k} => #{v}"] }.sort_by(&:first)
                        pp.seplist(explicit) do |kv|
                            pp.text kv[1]
                        end
                    end
                end

                pp.breakable
                pp.text "Defaults:"
                if !defaults.empty?
                    pp.nest(2) do
                        pp.breakable
                        defaults = self.defaults.map(&:to_s).sort
                        pp.seplist(defaults) do |v|
                            pp.text v.to_s
                        end
                    end
                end
            end

            # call-seq:
            #   add(default0, default1, key0 => value0)
            #   add([default0, default1], key0 => value0)
            #   add(dependency_injection)
            #
            # Add default and explicit selections in one call
            def add(*mappings)
                if mappings.size == 1 && mappings.first.kind_of?(DependencyInjection)
                    deps = mappings.first
                    explicit, defaults = deps.explicit, deps.defaults
                else
                    explicit, defaults = DependencyInjection.validate_use_argument(*mappings)
                end

                add_explicit(explicit)
                add_defaults(defaults)
                self
            end

            # Add a new dependency injection pattern to the current set
            #
            # The new mapping overrides existing mappings
            def add_explicit(mappings)
                explicit.merge!(mappings)
                @explicit = DependencyInjection.resolve_recursive_selection_mapping(explicit)
            end

            # Add a list of objects to the default list. 
            def add_defaults(list)
                @defaults |= list
                seen = Set.new
                @defaults.delete_if do |obj|
                    if seen.include?(obj)
                        true
                    else
                        seen << obj
                        false
                    end
                end
            end

            # Returns true if this object contains a selection for the given
            # criteria
            #
            # See #candidates_for for the description of the criteria list
            def has_selection?(*criteria)
                !candidates_for(*criteria).empty?
            end

            # Returns a list of candidates for the given selection criteria
            # based on the information in +self+
            def candidates_for(*criteria)
                if defaults.empty?
                    selection = self.explicit
                else
                    @resolved ||= resolve
                    return @resolved.candidates_for(*criteria)
                end

                criteria.each do |obj|
                    required_models = []
                    case obj
                    when String
                        if result = selection[obj]
                            return [result]
                        end
                    when InstanceRequirements
                        required_models = obj.models
                    when DataServiceModel
                        required_models = [obj]
                    else
                        if obj <= Component
                            required_models = [obj]
                        else
                            raise ArgumentError, "unknown criteria object #{obj}, expected a string or an InstanceRequirements object"
                        end
                    end

                    candidates = required_models.map do |m|
                        selection[m] || selection[m.name]
                    end.flatten.compact
                    if !candidates.empty?
                        return candidates
                    end
                end
                []
            end

            # Like #candidates_for, but returns a single match
            #
            # The match is either nil if there is an ambiguity (multiple
            # matches) or if there is no match.
            def selection_for(*criteria)
                candidates = candidates_for(*criteria)
                if candidates.size == 1
                    return candidates.first
                end
            end

            def initialize_copy(from)
                @explicit = from.explicit.map_value do |key, obj|
                    if obj then obj.dup else nil end
                end
                @defaults = Set.new
                from.defaults.each do |obj|
                    @defaults << obj.dup
                end
            end

            # Resolves the selections by generating a direct mapping (as a hash)
            # representing the required selection
            def resolve
                result = DependencyInjection.resolve_default_selections(explicit, self.defaults)
                DependencyInjection.new(DependencyInjection.resolve_recursive_selection_mapping(result))
            end

            # Recursively resolve the selections that are specified as strings
            # using the provided block
            def resolve_names(mapping = self.explicit, &block)
                map! do |v|
                    if v.respond_to?(:to_str)
                        DependencyInjection.resolve_selection_recursively(v, mapping)
                    elsif v.respond_to?(:resolve_names)
                        v.resolve_names(&block)
                        v
                    else v
                    end
                end
            end

            # Removes the unresolved instances from the list of selections
            #
            # So far, unresolved selections are the ones that are represented as
            # strings. The entries are not removed per se, but they are replaced
            # by nil, to mark "do not use" selections.
            def remove_unresolved
                defaults.delete_if { |v| v.respond_to?(:to_str) }
                map! do |value|
                    if value.respond_to?(:to_str)
                        nil
                    else value
                    end
                end
            end

            # Create a new DependencyInjection object, with a modified selection
            #
            # Like #map!, this method yields the [selection_key,
            # selected_instance] pairs to a block that must return a new value
            # for the for +selected_instance+.
            def map(&block)
                copy = dup
                copy.map!(&block)
            end

            # Changes the selections
            #
            # This method yields the [selection_key, selected_instance] pairs to
            # a block that must return a new value for the for
            # +selected_instance+. It modifies +self+
            def map!(&block)
                changed = false
                result = explicit.map_value do |k, v|
                    result = yield(v)
                    changed ||= (result != v)
                    result
                end
                if changed
                    @explicit = DependencyInjection.resolve_recursive_selection_mapping(explicit)
                end

                @defaults.map! do |v|
                    yield(v)
                end
                self
            end

            # Merge the selections in +other+ into +self+.
            #
            # If both objects provide selections for the same keys,
            # raises ArgumentError if the two selections are incompatible
            def merge(other)
                @explicit.merge!(other.explicit) do |match, model1, model2|
                    if model1 <= model2
                        model1
                    elsif model2 <= model1
                        model2
                    else
                        raise ArgumentError, "cannot use both #{model1} and #{model2} for #{match}"
                    end
                end
                @defaults |= other.defaults
            end

            # Helper method that resolves recursive selections in a dependency
            # injection mapping
            def self.resolve_recursive_selection_mapping(spec)
                spec.map_value do |key, value|
                    while (new_value = spec[value])
                        value = new_value
                    end
                    value
                end
            end

            # Helper method that resolves one single object recursively
            def self.resolve_selection_recursively(value, spec)
                while (new_value = spec[value])
                    value = new_value
                end
                value
            end

            # Helper methods that adds to a dependency inject mapping a list of
            # default selections
            #
            # Default selections are a list of objects for which no
            # specification is used. They are resolved as "select X for all
            # models of X for which there is no explicit selection already"
            def self.resolve_default_selections(using_spec, default_selections)
                if !default_selections || default_selections.empty?
                    return using_spec
                end

                Engine.debug do
                    Engine.debug "Resolving default selections"
                    default_selections.map(&:to_s).sort.each do |sel|
                        Engine.debug "    #{sel}"
                    end
                    Engine.debug "  into"
                    using_spec.map { |k, v| [k.to_s, v.to_s] }.sort.each do |k, v|
                        Engine.debug "    #{k} => #{v}"
                    end
                    Engine.debug "  rejections:"
                    break
                end

                result = using_spec.dup

                ambiguous_default_selections = Hash.new
                resolved_default_selections = Hash.new

                default_selections.each do |selection|
                    selection = resolve_selection_recursively(selection, using_spec)
                    selection.each_fullfilled_model do |m|
                        if using_spec[m]
                            Engine.debug do
                                Engine.debug "  rejected #{selection} for #{m}: already explicitely selected"
                                break
                            end
                        elsif ambiguous_default_selections.has_key?(m)
                            ambiguity = ambiguous_default_selections[m]
                            Engine.debug do
                                Engine.debug "  rejected #{selection} for #{m}: ambiguity with #{ambiguity.map(&:to_s).join(", ")}"
                                break
                            end
                            ambiguity << selection
                        elsif resolved_default_selections[m] && resolved_default_selections[m] != selection
                            removed = resolved_default_selections.delete(m)
                            ambiguous_default_selections[m] = [selection, removed].to_set
                            Engine.debug do
                                Engine.debug "  rejected #{removed} for #{m}: ambiguity with #{selection}"
                                break
                            end
                        elsif selection != m
                            resolved_default_selections[m] = selection
                        end
                    end
                end
                Engine.debug do
                    Engine.debug "  selected defaults:"
                    resolved_default_selections.each do |key, sel|
                        Engine.debug "    #{key.respond_to?(:short_name) ? key.short_name : key}: #{sel}"
                    end
                    break
                end
                result.merge!(resolved_default_selections)
            end

            # Helper method that separates the default selections from the
            # explicit selections in the call to #use
            #
            # @return <Hash, Array> the explicit selections and a list of
            #     default selections
            def self.validate_use_argument(*mappings)
                explicit = Hash.new
                defaults = Array.new
                mappings.each do |element|
                    if element.kind_of?(Hash)
                        explicit.merge!(element)
                    else
                        defaults << element
                    end
                end
                return explicit, defaults
            end
        end

        # Representation of a selection context, as a stack of
        # DependencyInjection objects
        #
        # This represents a prioritized set of selections (as
        # DependencyInjection objects). It is mainly used during instanciation
        # to find _what_ should be instanciated.
        #
        # In the stack, the latest selection added with #push takes priority
        # over everything that has been added before it. During resolution, if
        # nothing is found at a certain level, then the previous levels will be
        # queried.
        #
        # Use #selection_for and #candidates_for to query the selection. Use
        # #save, #restore and #push to manage the stack
        class DependencyInjectionContext
            StackLevel = Struct.new :resolver, :added_info

            # The stack of StackLevel objects added with #push
            attr_reader :stack
            # The resolved selections. When a query is made at a certain level
            # of the stack, it gets resolved into one single explicit selection
            # hash, to optimize repeated queries.
            attr_reader :state
            # The list of savepoints
            #
            # They are stored as sizes of +stack+. I.e. #restore simply resizes
            # +stack+ and +state+ to the size stored in +save.last+
            attr_reader :savepoints

            # Creates a new dependency injection context
            #
            # +base+ is the root selection context (can be nil). It can either
            # be a hash or a DependencyInjection object. In the first case, it
            # is interpreted as a selection hash usable in
            # DependencyInjection#use, and is converted to the corresponding
            # DependencyInjection object this way.
            def initialize(base = nil)
                @stack = []
                @state = []
                @savepoints = []

                # Add a guard on the stack, so that #push does not have to care
                stack << StackLevel.new(DependencyInjection.new, Hash.new)

                case base
                when Hash
                    deps = DependencyInjection.new(base)
                    push(deps)
                when DependencyInjection
                    push(base)
                when NilClass
                else
                    raise ArgumentError, "expected either a selection hash or a DependencyInjection object as base selection, got #{base}"
                end
            end

            def pretty_print(pp)
                current_state.pretty_print(pp)
            end

            def initialize_copy(obj)
                @stack = obj.stack.dup
                @state = obj.state.dup
                @savepoints  = obj.savepoints.dup
            end


            # Pushes the current state of the context. #restore will go back to
            # this exact state, regardless of the number of #push calls.
            #
            # The save/restore mechanism is stack-based, so when doing
            #
            #   save
            #   save
            #   restore
            #   restore
            #
            # The first restore returns to the state in the second save and the
            # second restore returns to the state in thef first save.
            def save
                if !block_given?
                    @savepoints << stack.size
                else
                    save
                    begin
                        yield
                    ensure
                        restore
                    end
                end
            end

            # Returns the resolved state of the selection stack, as a
            # DependencyInjection object.
            #
            # Calling #candidates_for and #selection_for on the resolved object
            # is equivalent to resolving the complete stack
            def current_state
                stack.last.resolver
            end

            # The opposite of #save
            def restore
                expected_size = @savepoints.pop
                if !expected_size
                    raise ArgumentError, "save/restore stack is empty"
                end

                @stack = stack[0, expected_size]
                if state.size > expected_size
                    @state = state[0, expected_size]
                end
            end

            # Returns all the candidates that match +criteria+ in the current
            # state of this context
            #
            # See DependencyInjection#candidates_for for the format of
            # +criteria+
            def candidates_for(*criteria)
                current_state.candidates_for(*criteria)
            end

            # Returns a non-ambiguous selection for the given criteria
            #
            # Returns nil if no selection is defined, or if there is an
            # ambiguity (i.e. multiple candidates exist)
            #
            # See DependencyInjection#candidates_for for the format of
            # +criteria+
            #
            # See also #candidates_for
            def selection_for(*criteria)
                current_state.selection_for(*criteria)
            end

            # Adds a new dependency injection context on the stack
            def push(spec)
                spec = DependencyInjection.new(spec)

                new_state = stack.last.resolver.dup
                # Resolve all names
                spec.resolve_names(new_state.explicit.merge(spec.explicit))
                # Resolve recursive selection, and default selections
                spec = spec.resolve
                # Finally, add it to the new state
                new_state.add(spec)
                # ... and to the stack
                stack << StackLevel.new(new_state, spec)
            end

            # Returns the StackLevel object representing the last added level on
            # the stack
            def top
                stack.last
            end

            # Removes the last dependency injection context stored on the stack,
            # and returns it.
            #
            # Will stop at the last saved context (saved with #save). Returns
            # nil in this case
            def pop
                if stack.size == 1
                    return
                end

                expected_size = @savepoints.last
                if expected_size && expected_size == stack.size
                    return
                end

                result = stack.pop
                if state.size > stack.size
                    @state = state[0, stack.size]
                end
                result
            end
        end

        # A representation of a selection matching a given requirement
        class InstanceSelection
            attr_reader :requirements

            attr_predicate :explicit?, true
            attr_accessor :selected_task
            attr_accessor :selected_services
            attr_accessor :port_mappings

            def initialize(requirements)
                @requirements = requirements
                @selected_services = Hash.new
                @port_mappings = Hash.new
            end

            # If this selection does not yet have an associated task,
            # instanciate one
            def instanciate(engine, context, options)
                requirements.narrow_model

                options[:task_arguments] ||= requirements.arguments
                if requirements.models.size == 1 && requirements.models.first.kind_of?(Class)
                    @selected_task = requirements.models.first.instanciate(engine, context, options)
                else
                    @selected_task = requirements.create_placeholder_task
                end

                selected_task.requirements.merge(self.requirements)
                selected_task
            end

            def self.compute_service_selection(task_model, required_services, user_call)
                result = Hash.new
                required_services.each do |required|
                    next if !required.kind_of?(DataServiceModel)
                    candidate_services =
                        task_model.find_all_services_from_type(required)

                    if candidate_services.size > 1
                        throw :invalid_selection if !user_call
                        raise AmbiguousServiceSelection.new(task_model, required, candidate_services)
                    elsif candidate_services.empty?
                        throw :invalid_selection if !user_call
                        raise NoMatchingService.new(self, task_model, required)
                    end
                    result[required] = candidate_services.first
                end
                result
            end

            def self.from_object(object, requirements, user_call = false)
                result = InstanceSelection.new(requirements)
                required_model = requirements.models

                object_requirements = InstanceRequirements.new
                case object
                when InstanceRequirements
                    result.requirements.merge(object)
                when InstanceSelection
                    result.selected_task = object.selected_task
                    result.selected_services = object.selected_services
                    result.port_mappings = object.port_mappings
                    result.requirements.merge(object.requirements)
                when DataServiceInstance
                    if !object.provided_service_model
                        raise InternalError, "#{object} has no provided service model"
                    end
                    required_model.each do |required|
                        result.selected_services[required] = object.provided_service_model
                    end
                    result.selected_task = object.task
                    object_requirements.require_model(object.task.model)
                when ProvidedDataService
                    required_model.each do |required|
                        result.selected_services[required] = object
                    end
                    object_requirements.require_model(object.component_model)
                when DataServiceModel
                    object_requirements.require_model(object)
                when Component
                    result.selected_task = object
                    result.selected_services = compute_service_selection(object.model, required_model, user_call)
                    object_requirements.require_model(object.model)
                else
                    if object < Component
                        object_requirements.require_model(object)
                        result.selected_services = compute_service_selection(object, required_model, user_call)
                    else
                        throw :invalid_selection if !user_call
                        raise ArgumentError, "invalid selection #{object}: expected a device name, a task instance or a model"
                    end
                end

                result.requirements.merge(object_requirements)
                result
            end

            def to_s
                "#<#{self.class}: #{requirements} selected_task=#{selected_task}>"
            end

            def pretty_print(pp)
                pp.text "InstanceSelection"
                pp.breakable
                pp.text "Selected: "
                selected_task.pretty_print(pp)
                pp.text "For: "
                pp.nest(2) do
                    pp.breakable
                    requirements.pretty_print(pp)
                end
            end
        end
    end
end


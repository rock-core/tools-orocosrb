module Orocos
    # Interface allowing to instanciate orogen-generated components in-process
    class ComponentLoader
        attr_reader :pkgconfig_loader

        def initialize(loader: Orocos.default_pkgconfig_loader)
            @pkgconfig_loader = loader
        end

        # Make a task library's task types available for deployment
        #
        # @param [String] name the task library name (e.g. logger)
        def load_task_library(name)
            path = @pkgconfig_loader.task_library_path_from_name(name)
            load_library(path)
        end
    end
end

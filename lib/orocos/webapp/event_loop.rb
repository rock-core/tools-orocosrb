module Orocos
    module WebApp
        def self.install_event_loop(period = 0.1)
            @async_event_loop_timer ||=
                EM.add_periodic_timer period do
                    Orocos::Async.event_loop.step
                end
        end

        def self.remove_event_loop
            EM.cancel_timer(@async_event_loop_timer)
            @async_event_loop_timer = nil
        end
    end
end

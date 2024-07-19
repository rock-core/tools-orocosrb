#include "rorocos.hh"

#include <rtt/types/Types.hpp>
#include <rtt/types/TypekitPlugin.hpp>
#include <rtt/types/TypekitRepository.hpp>
#include <rtt/base/PortInterface.hpp>
#include <rtt/transports/corba/TransportPlugin.hpp>
#include <rtt/internal/ConnFactory.hpp>

#include <rtt/deployment/ComponentLoader.hpp>

#include <rtt/OutputPort.hpp>
#include <rtt/base/InputPortInterface.hpp>

#include <typelib_ruby.hh>
#include <rtt/transports/corba/CorbaLib.hpp>

#include <rtt/TaskContext.hpp>
#include <rtt/transports/corba/TaskContextServer.hpp>
#include <rtt/transports/corba/CorbaDispatcher.hpp>
#include "rblocking_call.h"

#ifdef HAS_GETTID
#include <sys/syscall.h>
#endif

static VALUE cRubyTaskContext;
static VALUE cLocalRubyTaskContext;
static VALUE cLocalTaskContext;
static VALUE cComponentLoader;
static VALUE cLocalOutputPort;
static VALUE cLocalInputPort;

struct LocalRubyTaskContext : public RTT::TaskContext
{
    std::string model_name;

    RTT::Operation< ::std::string() > _getModelName;
    RTT::Operation< boost::int32_t() > ___orogen_getTID;
    RTT::OutputPort< ::boost::int32_t > _state;
    std::string getModelName() const
    { return model_name; }
    void setModelName(std::string const& value)
    { model_name = value; }

    LocalRubyTaskContext(std::string const& name)
        : RTT::TaskContext(name, TaskCore::PreOperational)
        , _getModelName("getModelName", &LocalRubyTaskContext::getModelName, this, RTT::ClientThread)
        , ___orogen_getTID("__orogen_getTID", &LocalRubyTaskContext::__orogen_getTID, this, RTT::OwnThread)
        , _state("state")
    {
        setupComponentInterface();
    }

    void setupComponentInterface()
    {
        provides()->addOperation( _getModelName)
            .doc("returns the oroGen model name for this task");
        provides()->addOperation( ___orogen_getTID)
            .doc("returns the thread ID of this task");
        _state.keepLastWrittenValue(false);
        _state.keepNextWrittenValue(true);
        ports()->addPort(_state);

        _state.keepLastWrittenValue(true);
        _state.write(getTaskState());
    }

    boost::int32_t __orogen_getTID() const
    {
        return syscall(SYS_gettid);
    }

    void report(int state) { _state.write(state); }
    void state(int state) { _state.write(state); }
    void error(int state)
    {
        _state.write(state);
        TaskContext::error();
    }
    void exception(int state)
    {
        _state.write(state);
        TaskContext::exception();
    }
    void fatal(int state)
    {
        _state.write(state);
        TaskContext::fatal();
    }
    struct StateExporter
    {
        RTT::TaskContext const& task;
        RTT::OutputPort<boost::int32_t>&   port;

        StateExporter(RTT::TaskContext const& task, RTT::OutputPort<int>& port)
            : task(task), port(port) {}
        ~StateExporter()
        {
            port.write(task.getTaskState());
        }
    };
    bool start()
    {
        StateExporter exporter(*this, _state);
        return RTT::TaskContext::start();
    }

    bool configure()
    {
        StateExporter exporter(*this, _state);
        return RTT::TaskContext::configure();
    }
    bool recover()
    {
        StateExporter exporter(*this, _state);
        return RTT::TaskContext::recover();
    }
    bool stop()
    {
        StateExporter exporter(*this, _state);
        return RTT::TaskContext::stop();
    }
    bool cleanup()
    {
        StateExporter exporter(*this, _state);
        return RTT::TaskContext::cleanup();
    }
    void fatal()
    { return fatal(RTT::TaskContext::FatalError); }
    void error()
    { return error(RTT::TaskContext::RunTimeError); }
    void exception()
    { return exception(RTT::TaskContext::Exception); }
};

struct RLocalTaskContext
{
    RTT::TaskContext* tc;
    RLocalTaskContext(RTT::TaskContext* tc)
        : tc(tc) {}
};

RTT::TaskContext& local_task_context(VALUE obj)
{
    RTT::TaskContext* tc = get_wrapped<RLocalTaskContext>(obj).tc;
    if (!tc)
        rb_raise(rb_eArgError, "accessing a disposed task context");
    return *tc;
}

LocalRubyTaskContext& local_ruby_task_context(VALUE obj)
{
    return dynamic_cast<LocalRubyTaskContext&>(local_task_context(obj));
}

static void local_task_context_dispose_internal(RLocalTaskContext* rtask)
{
    if (!rtask->tc)
        return;

    RTT::TaskContext* task = rtask->tc;

    // Ruby GC does not give any guarantee about the ordering of garbage
    // collection. Reset the dataflowinterface to NULL on all ports so that
    // delete_rtt_ruby_port does not try to access task->ports() while it is
    // deleted
    RTT::DataFlowInterface::Ports ports = task->ports()->getPorts();
    for (RTT::DataFlowInterface::Ports::const_iterator it = ports.begin();
            it != ports.end(); ++it)
    {
        (*it)->disconnect();
        (*it)->setInterface(0);
    }
    RTT::corba::TaskContextServer::CleanupServer(task);
    delete task;
    rtask->tc = 0;
}

static void delete_local_task_context(RLocalTaskContext* rtask)
{
    std::auto_ptr<RLocalTaskContext> guard(rtask);
    local_task_context_dispose_internal(rtask);
}

static VALUE local_ruby_task_context_new(VALUE klass, VALUE _name, VALUE use_naming)
{
    std::string name = StringValuePtr(_name);
    LocalRubyTaskContext* ruby_task = new LocalRubyTaskContext(name);
#if RTT_VERSION_GTE(2,8,99)
    ruby_task->addConstant<int>("CorbaDispatcherScheduler", ORO_SCHED_OTHER);
    ruby_task->addConstant<int>("CorbaDispatcherPriority", RTT::os::LowestPriority);
#else
    RTT::corba::CorbaDispatcher::Instance(ruby_task->ports(), ORO_SCHED_OTHER, RTT::os::LowestPriority);
#endif

    RTT::corba::TaskContextServer::Create(ruby_task, RTEST(use_naming));

    VALUE rlocal_ruby_task = Data_Wrap_Struct(cLocalRubyTaskContext, 0, delete_local_task_context, new RLocalTaskContext(ruby_task));
    rb_obj_call_init(rlocal_ruby_task, 1, &_name);
    return rlocal_ruby_task;
}

static VALUE local_task_context_dispose(VALUE obj)
{
    RLocalTaskContext& task = get_wrapped<RLocalTaskContext>(obj);
    local_task_context_dispose_internal(&task);
    return Qnil;
}

static VALUE local_task_context_ior(VALUE _task)
{
    RTT::TaskContext& task = local_task_context(_task);
    std::string ior = RTT::corba::TaskContextServer::getIOR(&task);
    return rb_str_new(ior.c_str(), ior.length());
}

static void delete_rtt_ruby_port(RTT::base::PortInterface* port)
{
    if (port->getInterface())
        port->getInterface()->removePort(port->getName());
    delete port;
}

static void delete_rtt_ruby_property(RTT::base::PropertyBase* property)
{
    delete property;
}

static void delete_rtt_ruby_attribute(RTT::base::AttributeBase* attribute)
{
    delete attribute;
}

/** call-seq:
 *     model_name=(name)
 *
 */
static VALUE local_ruby_task_context_set_model_name(VALUE _task, VALUE name)
{
    local_ruby_task_context(_task).setModelName(StringValuePtr(name));
    return Qnil;
}

static VALUE local_ruby_task_context_exception(VALUE _task)
{
    local_ruby_task_context(_task).exception();
    return Qnil;
}

/** call-seq:
 *     do_create_port(klass, port_name, orocos_type_name)
 *
 */
static VALUE local_ruby_task_context_create_port(VALUE _task, VALUE _is_output, VALUE _klass, VALUE _port_name, VALUE _type_name)
{
    std::string port_name = StringValuePtr(_port_name);
    std::string type_name = StringValuePtr(_type_name);
    RTT::types::TypeInfo* ti = get_type_info(type_name);
    if (!ti)
        rb_raise(rb_eArgError, "type %s is not registered on the RTT type system", type_name.c_str());
    RTT::types::ConnFactoryPtr factory = ti->getPortFactory();
    if (!factory)
        rb_raise(rb_eArgError, "it seems that the typekit for %s does not include the necessary factory", type_name.c_str());

    RTT::base::PortInterface* port;
    VALUE ruby_port;
    if (RTEST(_is_output))
        port = factory->outputPort(port_name);
    else
        port = factory->inputPort(port_name);

    ruby_port = Data_Wrap_Struct(_klass, 0, delete_rtt_ruby_port, port);
    local_task_context(_task).ports()->addPort(*port);

    VALUE args[4] = { rb_iv_get(_task, "@remote_task"), _port_name, _type_name, Qnil };
    rb_obj_call_init(ruby_port, 4, args);
    return ruby_port;
}

static VALUE local_ruby_task_context_remove_port(VALUE obj, VALUE _port_name)
{
    std::string port_name = StringValuePtr(_port_name);
    LocalRubyTaskContext& task(local_ruby_task_context(obj));
    RTT::DataFlowInterface& di(*task.ports());
    RTT::base::PortInterface* port = di.getPort(port_name);
    if (!port)
        rb_raise(rb_eArgError, "task %s has no port named %s", task.getName().c_str(), port_name.c_str());

    // Workaround a bug in RTT. The port's data flow interface is not reset
    port->setInterface(0);
    di.removePort(port_name);
    return Qnil;
}

/** call-seq:
 *     do_create_property(klass, port_name, orocos_type_name)
 *
 */
static VALUE local_ruby_task_context_create_property(VALUE _task, VALUE _klass, VALUE _property_name, VALUE _type_name)
{
    std::string property_name = StringValuePtr(_property_name);
    std::string type_name = StringValuePtr(_type_name);
    RTT::types::TypeInfo* ti = get_type_info(type_name);
    if (!ti)
        rb_raise(rb_eArgError, "type %s is not registered on the RTT type system", type_name.c_str());

    RTT::types::ValueFactoryPtr factory = ti->getValueFactory();
    if (!factory)
        rb_raise(rb_eArgError, "it seems that the typekit for %s does not include the necessary factory", type_name.c_str());

    RTT::base::PropertyBase* property = factory->buildProperty(property_name, "");
    VALUE ruby_property = Data_Wrap_Struct(_klass, 0, delete_rtt_ruby_property, property);
    local_task_context(_task).addProperty(*property);

    VALUE args[4] = { rb_iv_get(_task, "@remote_task"), _property_name, _type_name };
    rb_obj_call_init(ruby_property, 3, args);
    return ruby_property;
}

/** call-seq:
 *     do_create_attribute(klass, port_name, orocos_type_name)
 *
 */
static VALUE local_ruby_task_context_create_attribute(VALUE _task, VALUE _klass, VALUE _attribute_name, VALUE _type_name)
{
    std::string attribute_name = StringValuePtr(_attribute_name);
    std::string type_name = StringValuePtr(_type_name);
    RTT::types::TypeInfo* ti = get_type_info(type_name);
    if (!ti)
        rb_raise(rb_eArgError, "type %s is not registered on the RTT type system", type_name.c_str());

    RTT::types::ValueFactoryPtr factory = ti->getValueFactory();
    if (!factory)
        rb_raise(rb_eArgError, "it seems that the typekit for %s does not include the necessary factory", type_name.c_str());

    RTT::base::AttributeBase* attribute = factory->buildAttribute(attribute_name);
    VALUE ruby_attribute = Data_Wrap_Struct(_klass, 0, delete_rtt_ruby_attribute, attribute);
    local_task_context(_task).addAttribute(*attribute);

    VALUE args[4] = { rb_iv_get(_task, "@remote_task"), _attribute_name, _type_name };
    rb_obj_call_init(ruby_attribute, 3, args);
    return ruby_attribute;
}

static VALUE local_input_port_read(VALUE _local_port, VALUE type_name, VALUE rb_typelib_value, VALUE copy_old_data, VALUE blocking_read)
{
    RTT::base::InputPortInterface& local_port = get_wrapped<RTT::base::InputPortInterface>(_local_port);
    Typelib::Value value = typelib_get(rb_typelib_value);

    RTT::types::TypeInfo* ti = get_type_info(StringValuePtr(type_name));
    orogen_transports::TypelibMarshallerBase* typelib_transport =
        get_typelib_transport(ti, false);

    if (!typelib_transport || typelib_transport->isPlainTypelibType())
    {
        RTT::base::DataSourceBase::shared_ptr ds =
            ti->buildReference(value.getData());
        RTT::FlowStatus did_read;
        if (RTEST(blocking_read))
            did_read = blocking_fct_call_with_result(boost::bind(&RTT::base::InputPortInterface::read,&local_port,ds,RTEST(copy_old_data)));
        else
            did_read = local_port.read(ds, RTEST(copy_old_data));

        switch(did_read)
        {
            case RTT::NoData:  return Qfalse;
            case RTT::OldData: return INT2FIX(0);
            case RTT::NewData: return INT2FIX(1);
        }
    }
    else
    {
        orogen_transports::TypelibMarshallerBase::Handle* handle =
            typelib_transport->createHandle();
        // Set the typelib sample using the value passed from ruby to avoid
        // unnecessary convertions. Don't touch the orocos sample though.
        //
        // Since no typelib-to-orocos conversion happens, the conversion method
        // is not called and we don't have to catch a possible conversion error
        // exception
        //
        // If the remote side sends us invalid data, it will be rejected at the
        // CORBA layer
        typelib_transport->setTypelibSample(handle, value, false);
        RTT::base::DataSourceBase::shared_ptr ds =
            typelib_transport->getDataSource(handle);
        RTT::FlowStatus did_read;
        if (RTEST(blocking_read))
            did_read = blocking_fct_call_with_result(boost::bind(&RTT::base::InputPortInterface::read,&local_port,ds,RTEST(copy_old_data)));
        else
            did_read = local_port.read(ds, RTEST(copy_old_data));

        if (did_read == RTT::NewData || (did_read == RTT::OldData && RTEST(copy_old_data)))
        {
            typelib_transport->refreshTypelibSample(handle);
            Typelib::copy(value, Typelib::Value(typelib_transport->getTypelibSample(handle), value.getType()));
        }

        typelib_transport->deleteHandle(handle);
        switch(did_read)
        {
            case RTT::NoData:  return Qfalse;
            case RTT::OldData: return INT2FIX(0);
            case RTT::NewData: return INT2FIX(1);
        }
    }
    return Qnil; // Never reached
}
static VALUE local_input_port_clear(VALUE _local_port)
{
    RTT::base::InputPortInterface& local_port = get_wrapped<RTT::base::InputPortInterface>(_local_port);
    local_port.clear();
    return Qnil;
}

static VALUE local_output_port_write(VALUE _local_port, VALUE rb_type_name, VALUE rb_typelib_value)
{
    RTT::base::OutputPortInterface& local_port = get_wrapped<RTT::base::OutputPortInterface>(_local_port);
    Typelib::Value value = typelib_get(rb_typelib_value);
    std::string type_name(StringValuePtr(rb_type_name));

    orogen_transports::TypelibMarshallerBase* transport = 0;
    RTT::types::TypeInfo* ti = get_type_info(type_name);
    if (ti && ti->hasProtocol(orogen_transports::TYPELIB_MARSHALLER_ID))
    {
        transport =
            dynamic_cast<orogen_transports::TypelibMarshallerBase*>(ti->getProtocol(orogen_transports::TYPELIB_MARSHALLER_ID));
    }

    if (!transport)
    {
        RTT::base::DataSourceBase::shared_ptr ds =
            ti->buildReference(value.getData());
        local_port.write(ds);
    }
    else
    {
        orogen_transports::TypelibMarshallerBase::Handle* handle =
            transport->createHandle();

        try {
            transport->setTypelibSample(handle, static_cast<uint8_t*>(value.getData()));
        }
        catch(std::exception& e) {
            rb_raise(eCORBA, "failed to marshal %s: %s", type_name.c_str(), e.what());
        }
        RTT::base::DataSourceBase::shared_ptr ds =
            transport->getDataSource(handle);
        local_port.write(ds);
        transport->deleteHandle(handle);
    }
    return local_port.connected() ? Qtrue : Qfalse;
}

struct RComponentLoader {
    RTT::ComponentLoader component_loader;
};

static void delete_component_loader(RComponentLoader* loader) {
    delete loader;
}

VALUE component_loader_new(int argc, VALUE* argv, VALUE mod) {
    VALUE rloader = Data_Wrap_Struct(cComponentLoader, 0, delete_component_loader, new RComponentLoader());
    rb_obj_call_init(rloader, argc, argv);
    return rloader;
}

/* Make all task models of a task library available for instantiation
 *
 * You usually would want to use {#load_task_library} instead
 *
 * @param [String] path the full path to the task library .so file
 * @return [void]
 */
VALUE component_loader_load_library(VALUE self, VALUE path) {
    RComponentLoader& rloader(get_wrapped<RComponentLoader>(self));
    rloader.component_loader.loadLibrary(StringValuePtr(path));
    return Qnil;
}

/* Create a task context instance of the given type
 *
 * The type must have previously been made available using {#load_library}
 *
 * @param [String] instance_name the name of the created task context
 * @param [String] type_name the task context type name (e.g. logger::Logger)
 * @param [Boolean] use_naming whether the newly created task context should be
 *   registered on the name service
 * @return [void]
 */
VALUE component_loader_create_local_task_context(VALUE self, VALUE instance_name, VALUE type_name, VALUE use_naming) {
    RComponentLoader& rloader(get_wrapped<RComponentLoader>(self));
    RTT::TaskContext* tc = rloader.component_loader.loadComponent(StringValuePtr(instance_name), StringValuePtr(type_name));
    if (!tc) {
        rb_raise(rb_eArgError, "could not create a task of type %s", StringValuePtr(type_name));
    }
    RTT::corba::CorbaDispatcher::Instance(tc->ports(), ORO_SCHED_OTHER, RTT::os::LowestPriority);
    RTT::corba::TaskContextServer::Create(tc, RTEST(use_naming));

    VALUE rlocal_ruby_task = Data_Wrap_Struct(cLocalTaskContext, 0, delete_local_task_context, new RLocalTaskContext(tc));
    rb_obj_call_init(rlocal_ruby_task, 0, nullptr);
    return rlocal_ruby_task;
}

void Orocos_init_ruby_task_context(VALUE mOrocos, VALUE cTaskContext, VALUE cOutputPort, VALUE cInputPort)
{
    VALUE mRubyTasks = rb_define_module_under(mOrocos, "RubyTasks");
    cRubyTaskContext = rb_define_class_under(mRubyTasks, "TaskContext", cTaskContext);
    cLocalRubyTaskContext = rb_define_class_under(cRubyTaskContext, "LocalRubyTaskContext", rb_cObject);
    rb_define_singleton_method(cLocalRubyTaskContext, "new", RUBY_METHOD_FUNC(local_ruby_task_context_new), 2);
    rb_define_method(cLocalRubyTaskContext, "dispose", RUBY_METHOD_FUNC(local_task_context_dispose), 0);
    rb_define_method(cLocalRubyTaskContext, "ior", RUBY_METHOD_FUNC(local_task_context_ior), 0);
    rb_define_method(cLocalRubyTaskContext, "model_name=", RUBY_METHOD_FUNC(local_ruby_task_context_set_model_name), 1);
    rb_define_method(cLocalRubyTaskContext, "do_create_port", RUBY_METHOD_FUNC(local_ruby_task_context_create_port), 4);
    rb_define_method(cLocalRubyTaskContext, "do_remove_port", RUBY_METHOD_FUNC(local_ruby_task_context_remove_port), 1);
    rb_define_method(cLocalRubyTaskContext, "do_create_property", RUBY_METHOD_FUNC(local_ruby_task_context_create_property), 3);
    rb_define_method(cLocalRubyTaskContext, "do_create_attribute", RUBY_METHOD_FUNC(local_ruby_task_context_create_attribute), 3);
    rb_define_method(cLocalRubyTaskContext, "exception", RUBY_METHOD_FUNC(local_ruby_task_context_exception), 0);

    cComponentLoader = rb_define_class_under(mOrocos, "ComponentLoader", rb_cObject);
    rb_define_singleton_method(cComponentLoader, "new", RUBY_METHOD_FUNC(component_loader_new), -1);
    rb_define_method(cComponentLoader, "load_library", RUBY_METHOD_FUNC(component_loader_load_library), 1);
    rb_define_method(cComponentLoader, "create_local_task_context", RUBY_METHOD_FUNC(component_loader_create_local_task_context), 3);

    cLocalTaskContext = rb_define_class_under(mOrocos, "LocalTaskContext", rb_cObject);
    rb_define_method(cLocalTaskContext, "dispose", RUBY_METHOD_FUNC(local_task_context_dispose), 0);
    rb_define_method(cLocalTaskContext, "ior", RUBY_METHOD_FUNC(local_task_context_ior), 0);

    cLocalOutputPort = rb_define_class_under(mRubyTasks, "LocalOutputPort", cOutputPort);
    rb_define_method(cLocalOutputPort, "do_write", RUBY_METHOD_FUNC(local_output_port_write), 2);
    cLocalInputPort = rb_define_class_under(mRubyTasks, "LocalInputPort", cInputPort);
    rb_define_method(cLocalInputPort, "do_read", RUBY_METHOD_FUNC(local_input_port_read), 4);
    rb_define_method(cLocalInputPort, "do_clear", RUBY_METHOD_FUNC(local_input_port_clear), 0);
}


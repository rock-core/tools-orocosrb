#include <ruby.h>
#include <rtt/transports/ros/RosLib.hpp>
#include <ros/ros.h>

static VALUE eROSComError;

static VALUE ros_is_initialized(VALUE mod)
{
    return ros::isInitialized() ? Qtrue : Qfalse;
}

static VALUE ros_init(int argc, VALUE* _argv, VALUE mod)
{
    VALUE name, rest;
    rb_scan_args(argc, _argv, "1*", &name, &rest);

    size_t size = RARRAY_LEN(rest);
    std::vector<char const*> argv;
    argv.resize(size + 1);
    argv[0] = "";
    for (int i = 0; i < size; ++i)
    {
        VALUE element = RARRAY_PTR(rest)[i];
        argv[i + 1] = StringValuePtr(element);
    }

    if(!ros::isInitialized()){
        int argc = 0;
        ros::init(argc,NULL,StringValuePtr(name), ros::init_options::NoSigintHandler | ros::init_options::NoRosout);
      if(ros::master::check())
          ros::start();
      else{
          rb_raise(eROSComError, "cannot communicate with ROS master");
      }   
    }

    static ros::AsyncSpinner spinner(1); // Use 1 threads
    spinner.start();
    return Qnil;
}

static VALUE ros_shutdown()
{
    ros::shutdown();
    return Qnil;
}

void Orocos_init_ROS(VALUE mOrocos, VALUE eComError)
{
    VALUE mROS  = rb_define_module_under(mOrocos, "ROS");
    eROSComError = rb_define_class_under(mROS, "ComError", eComError);
    rb_define_singleton_method(mROS, "initialized?", RUBY_METHOD_FUNC(ros_is_initialized), 0);
    rb_define_singleton_method(mROS, "do_initialize", RUBY_METHOD_FUNC(ros_init), -1);
    rb_define_singleton_method(mROS, "shutdown", RUBY_METHOD_FUNC(ros_shutdown), 0);
    rb_const_set(mOrocos, rb_intern("TRANSPORT_ROS"),    INT2FIX(ORO_ROS_PROTOCOL_ID));
}

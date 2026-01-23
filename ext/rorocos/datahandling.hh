#ifndef OROCOS_EXT_RB_DATAHANDLING_HH
#define OROCOS_EXT_RB_DATAHANDLING_HH

#define RUBY_DONT_SUBST
#include <ruby.h>
#undef memcpy

#include <typelib_ruby.hh>

namespace CORBA {
    class Any;
}

// Unmarshals the data that is included in the given any into the memory held in
// +dest+. +dest+ must be holding a memory zone that is valid to hold a value of
// the given type.
VALUE corba_to_ruby(std::string const& type_name, Typelib::Value dest, CORBA::Any& src);

// Marshals the data that is held by +src+ into a CORBA::Any
CORBA::Any* ruby_to_corba(std::string const& type_name, Typelib::Value src);

#endif


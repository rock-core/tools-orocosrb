#ifndef RUBY_TASK_CONTEXT_HH
#define RUBY_TASK_CONTEXT_HH
#define RUBY_DONT_SUBST
#include <ruby.h>
#undef memcpy

void Orocos_init_ruby_task_context(VALUE mOrocos, VALUE cTaskContext, VALUE cOutputPort, VALUE cInputPort);

#endif


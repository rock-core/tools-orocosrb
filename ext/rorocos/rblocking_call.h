#ifndef _BLOCKING_FUNCTION_BASE___H
#define _BLOCKING_FUNCTION_BASE___H

//Helper templates to encapsulate rb_thread_blocking_region
//
#include <boost/function.hpp>
#include <boost/function_types/result_type.hpp>
#include <boost/bind/bind.hpp>
#define RUBY_DONT_SUBST
#include <ruby.h>
#undef memcpy
#include <ruby/thread.h>
#include <stdarg.h>
#include "rorocos.hh"

#define EXCEPTION_HANDLERS \
    catch(std::runtime_error &e) { this->rb_raise(rb_eRuntimeError, "%s", e.what());}\
    catch(std::exception& e) { this->rb_raise(rb_eException, "%s", e.what()); }

class BlockingFunctionBase
{
    public:
        VALUE exception_class;               //stores the exception class
        std::string exception_message;       //stores the message of the exeption

    protected:
        virtual void processing() = 0;
        virtual void abort() = 0;

        void blockingCall()
        {
            exception_class = Qnil;
            orocos_verify_thread_interdiction();

#if defined HAVE_RUBY_INTERN_H
            rb_thread_call_without_gvl(&BlockingFunctionBase::callProcessing, this,
                    &BlockingFunctionBase::callAbort, this);
#else
            callProcessing(this);
#endif
            // do NOT raise the pending exceptions here, otherwise this object
            // will not be destroyed properly
        }

        void rb_raise(VALUE exception_class)
        {
            this->exception_class = exception_class;
            this->exception_message.clear();
        }


        void rb_raise(VALUE exception_class, const char* format, ...)
        {
            char buffer[256];
            va_list args;
            va_start(args, format);
            vsnprintf(buffer,256, format, args);
            va_end (args);

            this->exception_class = exception_class;
            this->exception_message = buffer;
        }

        void rb_raise(VALUE exception_class, std::string const& message)
        {
            this->exception_class = exception_class;
            this->exception_message = message;
        }

        //called if no abort function is 
        //specified. We cannot test on empty() as
        //F and A might be of type boost::_bi::bind_t
        static void abort_default()
        {
        }

        /** Generic implementation of blocking function call mechanisms
         *
         * The main problem this deals with is that the Ruby exceptions must be
         * raised after all stack-based C++ objects are deleted
         */
        template<typename ResultT, typename BlockingFunctionT, typename F, typename A>
        static ResultT doCall(F processing, A abort)
        {
            VALUE exception_class;
            std::string exception_message;
            {
                BlockingFunctionT bf(processing, abort);
                bf.blockingCall();
                if (RTEST(bf.exception_class))
                {
                    exception_class   = bf.exception_class;
                    exception_message = bf.exception_message;
                }
                else return bf.ret();
            }
            // This is reached only if there is an exception
            ::rb_raise(exception_class, "%s", exception_message.c_str());
        }


    private:
        static void* callProcessing(void* ptr)
        {
            reinterpret_cast<BlockingFunctionBase*>(ptr)->processing();
            return NULL;
        }

        static void callAbort(void* ptr)
        {
            reinterpret_cast<BlockingFunctionBase*>(ptr)->abort();
        }
};

template<typename F, typename A = boost::function<void()> >
class BlockingFunction : public BlockingFunctionBase
{
    public:
        static void call(F processing, A abort = &BlockingFunction::abort_default)
        {
            return BlockingFunctionBase::doCall< void, BlockingFunction<F, A> >(processing, abort);
        }

        BlockingFunction(F processing, A abort)
            : processing_fct(processing),abort_fct(abort) { }

        virtual void processing()
        {
            try{processing_fct();}
            EXCEPTION_HANDLERS
        }

        void abort()
        {
            try{ abort_fct();}
            EXCEPTION_HANDLERS
        }

        F processing_fct;
        A abort_fct;

        void ret() {};
};

template<typename F, typename A = boost::function<void()> >
class BlockingFunctionWithResult : public BlockingFunction<F, A>
{
        typedef typename F::result_type result_t;

    public:
        static result_t call(F processing, A abort = &BlockingFunctionBase::abort_default)
        {
            return BlockingFunctionBase::doCall< result_t, BlockingFunctionWithResult<F,A> >(processing, abort);
        }

        BlockingFunctionWithResult(F processing, A abort):
            BlockingFunction<F,A>(processing, abort) {} 

        virtual void processing()
        {
            try{ return_val = this->processing_fct(); }
            EXCEPTION_HANDLERS
        }

        result_t return_val;
        result_t ret() { return return_val; }
};

// template functions can automatically pick up their template paramters
template<typename F, typename A>
void blocking_fct_call(F processing, A abort)
{
    BlockingFunction<F,A>::call(processing,abort);
}

template<typename F>
void blocking_fct_call(F processing)
{
    BlockingFunction<F>::call(processing);
}

template<typename F, typename A>
typename F::result_type blocking_fct_call_with_result(F processing, A abort)
{
    return BlockingFunctionWithResult<F,A>::call(processing,abort);
}

template<typename F>
typename F::result_type blocking_fct_call_with_result(F processing)
{
    return BlockingFunctionWithResult<F>::call(processing);
}

#endif

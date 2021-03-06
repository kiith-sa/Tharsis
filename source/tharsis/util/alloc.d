//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Overridable allocation/deallocation functions for Tharsis.
module tharsis.util.alloc;


import core.stdc.stdlib;


/// The default allocation function (just a nothrow malloc wrapper).
void[] nothrowMalloc(const size_t bytes, TypeInfo type) nothrow
{
    static void* malloc(size_t bytes)
    {
        return core.stdc.stdlib.malloc(bytes);
    }

    void* resultPtr = (cast(void* function(size_t) nothrow)&malloc)(bytes);
    void[] result = resultPtr[0 .. bytes];
    return result;
}

/// The default deallocation function (just a nothrow free wrapper).
void nothrowFree(void[] data) nothrow 
{
    static void free(void* ptr)
    {
        core.stdc.stdlib.free(ptr);
    }
    assert(data !is null, "Trying to free null data");
    (cast(void function(void*) nothrow)&free)(data.ptr);
}

/// The allocation function used to allocate most memory used by Tharsis.
/// 
/// Can be overridden to point to another function, but this can only be done at 
/// startup before Tharsis allocates anything. In that case, freeMemory must be 
/// overridden as well.
///
/// Params: bytes = The number of bytes to allocate.
///         type  = Type information about the allocated type
///                 (useful for debugging/diagnostics).
///
/// Returns: Allocated data as a void[] array.
__gshared void[] function(const size_t bytes, TypeInfo type) nothrow allocateMemory 
    = &nothrowMalloc;

/// The free function used to free most memory used by Tharsis.
///
/// Can be overridden to point to another function, but this can only be done at 
/// startup before Tharsis allocates anything. In that case, freeMemory must be 
/// overridden as well.
///
/// Params: data = The data to deallocate. Must not be null.
__gshared void function(void[] data) nothrow freeMemory = &nothrowFree;

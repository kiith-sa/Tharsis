//          Copyright Ferdinand Majerech 2013-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/** Analysis and type information of [Processes](../concepts/process.html) and their
 * [process()](../concepts/process.html#process-method) methods.
 *
 * Used mostly by Tharsis internals.
 */
module tharsis.entity.processtypeinfo;

import std.algorithm;
import std.array;
import std.conv;
import std.string;
import std.traits;
import std.typecons;
import std.typetuple;

import tharsis.entity.componenttypeinfo;
import tharsis.util.bitmanip;
import tharsis.util.traits;
import tharsis.util.typetuple;


/// Get all overloads of the `process()` method in a given Process type.
template processOverloads(Process)
{
    alias processOverloads = MemberFunctionsTuple!(Process, "process");
}
unittest
{
    class P
    {
        void process(int a, float b)   {}
        void process(float a, float b) {}
    }
    static assert(processOverloads!P.length == 2);
}

/// Get all past component types read by `process()` methods of a Process.
template AllPastComponentTypes(Process)
{
    alias overloads             = processOverloads!Process;
    alias RawPastTypes          = staticMap!(PastComponentTypes, overloads);
    alias AllPastComponentTypes = NoDuplicates!RawPastTypes;
}
unittest
{
    struct AComponent{enum ComponentTypeID = 1;}
    struct BComponent{enum ComponentTypeID = 2;}
    struct CComponent{enum ComponentTypeID = 3;}
    class S
    {
        void process(ref immutable(AComponent) a, ref immutable(BComponent) b){};
        void process(ref immutable(AComponent) a, ref immutable(CComponent) b){};
    }
    static assert(AllPastComponentTypes!S.length == 3);
}

/** Is the specified type an EntityAccess type?
 *
 * EntityAccess, aka EntityManager.Context, is passed to some
 * [process()](../concepts/process.html#process-method) functions to access entity info.
 */
template isEntityAccess(T)
{
    alias isEntityAccess = hasMember!(T, "isEntityAccess_");
}

/// Get past component types read by specified `process()` method.
template PastComponentTypes(alias ProcessFunc)
{
    mixin validateProcessMethod!ProcessFunc;
    // Get the actual component type (Param may be a slice).
    template BaseType(Param)
    {
        static assert(!isPointer!Param, "Past components can't be passed by pointer");
        static if(isArray!Param) { alias BaseType = typeof(Param.init[0]); }
        else                     { alias BaseType = Param; }
    }

    // Past components are passed by const.
    alias constTypes         = ConstTypes!(ParameterTypeTuple!ProcessFunc);

    alias constComponents    = Filter!(templateNot!isEntityAccess, constTypes);
    // Get the actual component types.
    alias baseTypes          = staticMap!(BaseType, constComponents);
    // Remove qualifiers such as const.
    alias PastComponentTypes = UnqualAll!baseTypes;
}

/// Get a sorted array of IDs of past component types read by a `process()` method.
template pastComponentIDs(alias ProcessFunc)
{
    enum pastComponentIDs = componentIDs!(PastComponentTypes!ProcessFunc);
}

/** Get the "raw" future component type written by a
 * [process()](../concepts/process.html#process-method) method
 *
 * The raw type includes any qualifiers, `ref`/`*`/`[]`, as specified in the signature
 */
template RawFutureComponentType(alias ProcessFunc)
{
    static if(futureComponentIndex!ProcessFunc != size_t.max)
    {
        enum paramIndex = futureComponentIndex!ProcessFunc;
        alias RawFutureComponentType = ParameterTypeTuple!ProcessFunc[paramIndex];
    }
    else
    {
        static assert(false, "Can't get a process() method %s writes no future component"
                             .format(typeof(ProcessFunc).stringof));
    }
}

/// Get the future component type written by a `process()` method.
template FutureComponentType(alias ProcessFunc)
{
private:
    alias FutureParamType = Unqual!(RawFutureComponentType!ProcessFunc);

public:

    // Get the actual component type (components may be passed by slice).
    static if(isArray!FutureParamType)
    {
        alias FutureComponentType = typeof(FutureParamType.init[0]);
    }
    else static if(isPointer!FutureParamType)
    {
        alias FutureComponentType = typeof(*FutureParamType);
    }
    else
    {
        alias FutureComponentType = FutureParamType;
    }
}

/// Does a [process()](../concepts/process.html#process-method) method write to a future
/// component?
template hasFutureComponent(alias ProcessFunc)
    if(isCallable!ProcessFunc)
{
    enum hasFutureComponent = futureComponentIndex!ProcessFunc != size_t.max;
}

/// Does a Process write to some future component?
template hasFutureComponent(Process)
{
    enum hasFutureComponent = __traits(compiles, Process.FutureComponent.sizeof);
}

/** Does a [process()](../concepts/process.html#process-method) method write to a future
 * component by pointer?

 *
 * Writing by pointer allows nulling it, allowing to remove (i.e. to not add into future
 * state) the component from an entity.
 */
template futureComponentByPointer(alias ProcessFunc)
{
    enum futureComponentByPointer =
        hasFutureComponent!ProcessFunc && isPointer!(RawFutureComponentType!ProcessFunc);
}

/** If ProcessFunc writes to a future [component](../concepts/component.html), return its
 * index in the parameter list. Otherwise return `size_t.max`.
 */
size_t futureComponentIndex(alias ProcessFunc)()
{
    size_t result = size_t.max;
    alias ParamTypes = ParameterTypeTuple!ProcessFunc;
    foreach(idx, paramStorage; ParameterStorageClassTuple!ProcessFunc)
    {
        // Future component is either passed by out, or by a ref pointer, or
        // (MultiComponent types) by a ref slice (array).
        if(paramStorage & ParameterStorageClass.out_
           || (isPointer!(ParamTypes[idx]) && paramStorage & ParameterStorageClass.ref_)
           || (isArray!(ParamTypes[idx]) && paramStorage & ParameterStorageClass.ref_))
        {
            assert(result == size_t.max, "process() method with multiple future components");
            result = idx;
        }
    }
    return result;
}

/** Get a tuple containing compile-time information about every parameter of a
 * [process()](../concepts/process.html#process-method) method.
 *
 * Each element of a tuple is a ParamInfo template, which contains various information
 * about the corresponding parameter of the
 * [process()](../concepts/process.html#process-method) method.
 */
template processMethodParamInfo(alias Method)
{
    alias ParamTypes          = ParameterTypeTuple!Method;
    alias ParamStorageClasses = ParameterStorageClassTuple!Method;

    /** Information about the [process()](../concepts/process.html#process-method) method
     * parameter at specified index.
     *
     * Note:
     *
     * There is one more member, which only exists if  `isComponent == true`: $(BR)
     * ``alias Component``: specifies the actual component type, with any slice/pointer
     * information removed.
     */
    template ParamInfo(int i)
    {
        /// Type of the parameter.
        alias Param        = ParamTypes[i];
        /// Storage class of the parameter.
        enum storage       = ParamStorageClasses[i];
        /// Is the parameter a slice? (used with
        /// [MultiComponents](../concepts/component.html#multicomponent))
        enum isSlice       = isArray!Param;
        /// Is the parameter a pointer? (used for optional future components)
        enum isPtr         = isPointer!Param;
        /// Is the parameter passed by `ref`?
        enum isRef         = storage & ParameterStorageClass.ref_;
        /// Is the parameter passed by `out`?
        enum isOut         = storage & ParameterStorageClass.out_;
        /// Name of the parameter type.
        enum ParamTypeName = Param.stringof;
        /// Is the parameter an EntityAccess (EntityManager.Context) struct?
        enum isEntityAccess = .isEntityAccess!Param;
        /// Is the parameter a [component](../concepts/component.html)?
        enum isComponent    = !isEntityAccess;
        /** If the parameter is a component, the Component alias specifies the component
         * type (with any slice or pointer information removed).
         */
        // Get the actual component type (Param may be a pointer or slice).
        static if(isComponent)
        {
            static if(isSlice)    { alias Component = typeof(Param.init[0]); }
            else static if(isPtr) { alias Component = typeof(*Param.init); }
            else                  { alias Component = Param; }
        }
    }

    alias processMethodParamInfo = staticMap!(ParamInfo, tupleIndices!ParamTypes);
}

/// Validate a [process()](../concepts/process.html#process-method) method, triggering
/// a compile-time error if invalid.
template validateProcessMethod(alias Function)
{
    // Return type does not matter; it just allows us to call this method with CTFE when
    // this mixin is used.
    typeof(null) validate()
    {
        uint futureCount = 0;
        bool[size_t] pastIDs;

        void testFutureComponent(alias Info)()
        {
            ++futureCount;
            // If slice is used, the param is a MultiComponent. ref is required to allow
            // the Process to downsize the slice.
            assert(!Info.isSlice || Info.isRef,
                   "Slice for a future MultiComponent of a process() method must be 'ref'");
            // Slice is not used; the param is not a MultiComponent out is used when the
            // future component is always written, ref pointer also allows _not to write_
            // the component into future state.
            assert(Info.isSlice || (Info.isPtr && Info.isRef) || (!Info.isPtr && Info.isOut),
                   "Future non-multi component of a process() method must be 'out' or a "
                   "'ref' pointer (" ~ Info.ParamTypeName ~ ") - or maybe this is not "
                   "supposed to be a future component but you forgot 'const'?");
        }

        void testPastComponent(alias Info)()
        {
            assert(!Info.isPtr, "Past components must not be passed by pointer");
            assert((Info.Component.ComponentTypeID in pastIDs) == null,
                   "Two past components of the same type (or of types with the same "
                   "ComponentTypeID) in a process() method signature");

            // MultiComponent past slices must have the default storage class so the
            // Process may not change the size of the passed slice.
            assert(!Info.isSlice || Info.storage == ParameterStorageClass.none,
                   "Slice for a past MultiComponent of a process() method must not be "
                   "'out', 'ref', 'scope' or 'lazy'");

            // Non-multi past components are passed by (const) ref.
            assert(Info.isSlice || Info.isRef,
                   "Past components of a process() method must be 'ref'");

            // Remember this past component to check for duplicates.
            pastIDs[Info.Component.ComponentTypeID] = true;
        }

        alias paramInfo = processMethodParamInfo!Function;
        size_t countMutable;
        foreach(Info; paramInfo) static if(Info.isComponent)
        {
            static if(isMutable!(Info.Component))
            {
                ++countMutable;
            }
        }
        assert(countMutable <= 1,
               "More than 1 mutable Component parameter in a process() method; only one "
               "parameter (the future component) may be mutable");

        foreach(Info; paramInfo)
        {
            static if(Info.isEntityAccess)
            {
                assert(!isMutable!(Info.Param), "Context parameter of process() must be const");
            }
            else static if(Info.isComponent)
            {
                alias Component = Info.Component;
                assert((Unqual!Component).stringof.endsWith("Component"),
                       "A non-Context parameter type to a process() method with name not "
                       "ending by \"Component\": " ~ Info.ParamTypeName);
                // MultiComponents must be passed by slices.
                assert(!Info.isSlice || isMultiComponent!Component,
                       "A non-MultiComponent passed by slice as a future component of a "
                       "process() method");
                // Other component types may _not_ be passed by slices.
                assert(Info.isSlice || !isMultiComponent!Component,
                       "A MultiComponent not passed by slice as a past component of a "
                       "process() method");

                static if(isMutable!Component) { testFutureComponent!Info(); }
                else                           { testPastComponent!Info(); }
            }
            else
            {
                assert(false, "A process() method with a non-Context, non-Component param");
            }
        }
        assert(futureCount <= 1,
               "A process() method with more than 1 future (non-const) component type");
        return null;
    }

    enum dummy = validate();
}


/// Validate a Process type, triggering a compile-time error if invalid.
mixin template validateProcess(Process)
{
    // For now processes must be classes.
    static assert(is(Process == class), "Processes must be classes");
    alias overloads = processOverloads!Process;
    // A Process without a process() method is not a Process.
    static assert(overloads.length > 0,
        "A Process must have at least one process() method");

    // Validate process() methods. Mixins don't work in CTFE; directly call validate().
    enum dummyValidateOverloads =
    {
        foreach(o; overloads) { validateProcessMethod!o.validate(); }
        return true;
    }();

    static if(hasFutureComponent!Process)
    {
        // Ensure all process() methods write the Process-specified FutureComponent.
        alias FutureComponent = Process.FutureComponent;
        enum dummyCheckFutureComponent =
        {
            foreach(o; overloads)
            {
                static assert(is(FutureComponentType!o == FutureComponent),
                    "process() method of a Process with a FutureComponent must write that "
                    "FutureComponent (have exactly one non-const reference, pointer or "
                    "slice (for MultiComponents) parameter, which must be of that future "
                    "component type). \nMethod breaking this rule: %s\n Future component "
                    "type written by that method: %s\n"
                    .format(typeof(o).stringof, (FutureComponentType!o).stringof));
            }
            return true;
        }();
    }
    else
    {
        // Ensure no process() methods write any FutureComponent.
        enum dummyCheckFutureComponent =
        {
            foreach(o; overloads)
            {
                static assert(!hasFutureComponent!o,
                    "process() method/s of a Process without a FutureComponent mustn't "
                    "write any future components (must not have non-const reference, "
                    "pointer or slice parameters) \nMethod breaking this rule: %s\n"
                    .format(typeof(o).stringof));
            }
            return true;
        }();
    }
}


/** Prioritize overloads of the [process()](../concepts/process.html#process-method) method
 * from [process](../concepts/process.html) P.
 *
 * Returns: Array of pairs sorted from the most specific `process()` overload (reads the
 *          most past components) to the most general (fewest past components). The first
 *          member of each pair is a string containing comma-separated IDs of past
 *          component types the overload reads; the second member is the index of the
 *          overload in processOverloads!P.
 *
 * Note:
 *
 * Different `process()` overloads read different past components.  Which overload to call
 * is ambiguous if there are two overloads with different past components but no overload
 * handling the union of these components, since there might be an entity with components
 * matching both overloads.
 *
 * **Example:** if one `process()` method reads components *A and B*, another reads *B, C*
 * and an entity has *A, B, C*, we don't know which overload to call. This will trigger an
 * error, requiring the user to define another `process()` overload reading *A, B, C*.
 * This overload will take precedence as it is unambiguosly more specific than both
 * previous overloads.
 */
Tuple!(string, size_t)[] prioritizeProcessOverloads(P)()
{
    // All overloads of the process() method in P.
    alias overloads = processOverloads!P;

    // Keys are component combinations handled by process() overloads, values are the
    // indices of process() overloads handling each combination.
    size_t[immutable(ushort)[]] cases;

    // For each pair of process() overloads (even if o1 and o2 are the same):
    foreach(i1, o1; overloads) foreach(i2, o2; overloads)
    {
        // A union of IDs of the past component types read by o1 and o2.
        auto combined = pastComponentIDs!o1.setUnion(pastComponentIDs!o2).uniq.array;

        // We've already found an overload for this combination.
        if((combined in cases) != null) { continue; }

        // Find the overload handling the combined past components read by o1 and o2. (If
        // o1 and o2 are the same, this will also find the same overload).
        size_t handlerOverload = size_t.max;
        foreach(i, ids; staticMap!(pastComponentIDs, overloads))
        {
            if(ids == combined)
            {
                handlerOverload = i;
                break;
            }
        }

        assert(handlerOverload != size_t.max, "Ambigous process() overloads in %s: %s, "
               "%s. Add overload handling past components processed by both overloads: %s"
               .format(P.stringof, typeof(o1).stringof, typeof(o2).stringof, combined));

        cases[cast(immutable(ushort)[])combined] = handlerOverload;
    }

    // The result must be an ordered array.
    Tuple!(string, size_t)[] result;
    foreach(ids, overload; cases)
    {
        assert(!result.canFind!(pair => pair[1] == overload),
               "Same overload assigned to multiple component combinations\n result: %s\n "
               "ids: %s\n overload: %s\n".format(result, ids, overload));

        result ~= tuple(ids.map!(to!string).join(", "), overload);
    }
    // Sort from most specific (reading most past components) to most general process() methods.
    result.sort!((a, b) => a[0].split(",").length > b[0].split(",").length);
    return result;
}

//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// A range used to iterate over entities in EntityManager.
module tharsis.entity.entityrange;


import std.algorithm;
import std.array;
import std.exception: assumeWontThrow;
import std.stdio;
import std.string;
import std.typetuple;

import tharsis.entity.componenttypeinfo;
import tharsis.entity.componenttypemanager;
import tharsis.entity.entitypolicy;
import tharsis.entity.entity;
import tharsis.entity.entityid;
import tharsis.entity.lifecomponent;
import tharsis.entity.processtypeinfo;
import tharsis.util.mallocarray;

/** Used to provide direct access to entity components to process() methods.
 *
 * Also known as EntityManager.Context.
 */
//  Always used as a part of EntityRange.
struct EntityAccess(EntityManager)
{
package:
    /* Index of the past entity we're currently reading.
     *
     * Updated by nextPastEntity().
     */
    union
    {
        size_t pastEntityIndex_ = 0;
        const size_t pastEntityIndex;
    }

    // Hack to allow process type info to figure out that an EntityAccess argument is not
    // a component argument.
    enum isEntityAccess_ = true;

private:
    /* Past entities in the entity manager.
     *
     * Past entities that are not alive are ignored.
     */
    immutable(Entity[]) pastEntities_;

    // Stores past components of all entities.
    immutable(EntityManager.ComponentStateT)* pastComponents_;

public:
    /// Entity currently being processed. Located here for fast r/w access.
    union
    {
        private Entity currentEntity_;
        const Entity entity;
    }

private:
    // Provides access to component type info.
    AbstractComponentTypeManager componentTypeMgr_;

    /// No default construction or copying.
    @disable this();
    @disable this(this);

public:
    /** Access a past (non-multi) [component](../concepts/component.html) in *any* past entity.
     *
     * This is a relatively slow way to access components, but allows to access components
     * of any entity. Should only be used when necessary.
     *
     * Params: Component = Type of component to access.
     *         entity    = ID of the entity to access. Must be an ID of an existing past entity.
     *
     * Returns: Pointer to the past component if the entity contains such a component;
     *          `null` otherwise.
     */
    immutable(Component)* pastComponent(Component)(const EntityID entity) nothrow const
        if(!isMultiComponent!Component)
    {
        auto raw = rawPastComponent(Component.ComponentTypeID, entity);
        return raw.isNull ? null : cast(immutable(Component)*)raw.componentData.ptr;
    }

    /** Access a past (non-multi) [component](../concepts/component.html) in _any_ past entity
     * as raw data.
     *
     * Params:
     *
     * typeID   = Type ID of component to access. Must be an ID of a registered component type.
     * entityID = ID of the entity to access. Must be an ID of an existing past entity.
     *
     * Returns: A RawComponent representation of the past component if the entity contains
     *          such a component; null RawComponent otherwise.
     */
    ImmutableRawComponent rawPastComponent(const ushort typeID, const EntityID entityID)
        nothrow const
    {
        assert(!componentTypeMgr_.componentTypeInfo[typeID].isMulti,
               "rawPastComponent can't access components of MultiComponent types");

        // Fast path when accessing a component in the current past entity.
        if(this.entity.id == entityID)
        {
            return componentOfEntity(typeID, pastEntityIndex_);
        }

        // If accessing a component in another past entity, binary search to find the
        // entity with matching ID (entities are sorted by ID).
        auto slice = pastEntities_[];
        while(!slice.empty)
        {
            const size_t index = slice.length / 2;
            const EntityID mid = slice[index].id;
            if(mid > entityID)       { slice = slice[0 .. index]; }
            else if (mid < entityID) { slice = slice[index + 1 .. $]; }
            else                     { return componentOfEntity(typeID, index); }
        }

        // If this happens, the user passed an invalid entity ID or we have a bug.
        assert(false, "Couldn't find an entity with specified ID");
    }

package:
    // Construct an EntityAccess for entities of specified entity manager.
    this(EntityManager entityManager) @trusted pure nothrow @nogc
    {
        pastEntities_     = entityManager.past_.entities;
        if(!pastEntities_.empty) { currentEntity_ = pastEntities_[0]; }
        pastComponents_   = &entityManager.past_.components;
        componentTypeMgr_ = entityManager.componentTypeMgr_;
    }

    // Move to the next past entity (called by EntityRange).
    void nextPastEntity() @safe pure nothrow @nogc
    {
        ++pastEntityIndex_;
        if(pastEntityIndex_ < pastEntities_.length)
        {
            currentEntity_ = pastEntities_[pastEntityIndex_];
        }
    }

private:
    // Get the component with type typeID of past entity at index index.
    auto componentOfEntity(const ushort typeID, const size_t index) nothrow const
    {
        auto pastComponents  = &((*pastComponents_)[typeID]);
        const componentCount = pastComponents.counts[index];
        if(0 == componentCount)
        {
            return ImmutableRawComponent(nullComponentTypeID, null);
        }

        const offset = pastComponents.offsets[index];
        assert(offset != size_t.max, "Offset not set");

        auto raw           = pastComponents.buffer.committedComponentSpace;
        auto componentSize = componentTypeMgr_.componentTypeInfo[typeID].size;
        auto byteOffset    = offset * componentSize;
        auto componentData = raw[byteOffset .. byteOffset + componentSize];
        return ImmutableRawComponent(typeID, componentData);
    }
}

package:

/* A range used to iterate over entities and their components in EntityManager.
 *
 * Used when executing Process to read past entities/components and to provide space for
 * future components. Iterates over _all_ past entities; matchComponents() determines if
 * the current entity has components required by any process() method.
 */
struct EntityRange(EntityManager, Process)
{
package:
    alias Policy         = EntityManager.EntityPolicy;
    /// Data type used to store component counts (16 bit uint by default).
    alias ComponentCount = EntityManager.ComponentCount;
    /// Past component types read by _all_ process() methods of Process.
    alias InComponents   = AllPastComponentTypes!Process;

private:
    /* Stores the slice and index for past entities.
     *
     * Separate from EntityRange; EntityAccess can be passed to process() methods for
     * direct access to the past entity and its components. Still, EntityRange directly
     * updates the past entity index inside.
     */
    EntityAccess!EntityManager entityAccess_;

    /* True if the Process does not write to any future component. Usually such processes
     * only read past components and produce some kind of output.
     */
    enum noFuture = !hasFutureComponent!Process;

    /* Indices to components of current entity in past component buffers. Only the indices
     * of iterated component types are used.
     */
    size_t[maxComponentTypes!Policy] componentOffsets_;

    // Index of the future entity we're currently writing to.
    size_t futureEntityIndex_ = 0;

    /* Future entities in the entity manager.
     *
     * Used to check if the current past and future entity is the same.
     */
    const(Entity[]) futureEntities_;

    static if(!noFuture)
    {

    // Future component written by the process (if any).
    alias FutureComponent = Process.FutureComponent;

    /* Number of future components (of type Process.FutureComponent) written to the current
     * future entity.
     *
     * Ease bug detection with a ridiculous value.
     */
    ComponentCount futureComponentCount_ = ComponentCount.max;

    /* Index of the first future component  for the current entity.
     *
     * Used to update ComponentTypeStateT.offsets .
     */
    uint futureComponentOffset_ = 0;

    /* Buffer and component count for future components written by Process.
     *
     * We can't keep a typed slice as the internal buffer may get reallocated; so we cast
     * on every future component access.
     *
     * Note that the counts/offsets buffers in futureComponents_ are *uninitialized* and
     * may contain random values. They should never be read, only written.
     */
    EntityManager.ComponentTypeStateT* futureComponents_;

    }

    /* Mixin slices to access past components, and pointers to component count buffers
     * to read the number of components of a type per entity.
     *
     * These are typed slices of untyped buffers in the ComponentBuffer of each component
     * type. Past components can also be accessed through EntityAccess.pastComponents_;
     * these slices are a performance optimization.
     */
    mixin(pastComponentBuffers());

    /* All processed component types.
     *
     * NoDuplicates! is used to avoid having two elements for the same type if the process
     * reads a builtin component type.
     */
    alias ProcessedComponents = NoDuplicates!(TypeTuple!(InComponents, BuiltinComponents));

    // (CTFE) Get name of component buffer for specified component type.
    static string bufferName(C)() @trusted
    {
        return "buffer%s_".format(C.ComponentTypeID);
    }

    // (CTFE) Get name of component count buffer for specified component type.
    static string countsName(ushort ID)() @trusted
    {
        return "counts%s_".format(ID);
    }

    /* (CTFE) For each processed past component type, generate 2 data members: component
     * buffer and component count buffer.
     */
    static string pastComponentBuffers()
    {
        string[] parts;
        // Component counts should be near each other, not interleaved with buffers,
        // to decrease cache misses.
        foreach(index, Component; ProcessedComponents)
        {
            version(assert)
            {
                parts ~= q{
                immutable(ComponentCount[]) %s;
                }.format(countsName!(Component.ComponentTypeID));
            }
            else
            {
                parts ~= q{
                immutable(ComponentCount*) %s;
                }.format(countsName!(Component.ComponentTypeID));
            }
        }
        foreach(index, Component; ProcessedComponents)
        {
            parts ~= q{
            immutable(ProcessedComponents[%s][]) %s;
            }.format(index, bufferName!Component);
        }
        return parts.join("\n");
    }

    /// No default construction or copying.
    @disable this();
    @disable this(this);

package:
    /// Construct an EntityRange to iterate over past entities of passed entity manager.
    this(EntityManager entityManager)
    {
        entityAccess_ = EntityAccess!EntityManager(entityManager);
        futureEntities_ = entityManager.future_.entities;

        immutable(EntityManager.ComponentStateT)* pastComponents =
            &entityManager.past_.components;
        // Init component/component count buffers for processed past component types.
        foreach(index, Component; ProcessedComponents)
        {
            enum id  = Component.ComponentTypeID;
            // Untyped component buffer to cast to a typed slice.
            auto raw = (*pastComponents)[id].buffer.committedComponentSpace;

            version(assert)
            {
                mixin(q{
                %s = cast(immutable(ProcessedComponents[%s][]))raw;
                %s = (*pastComponents)[id].counts[];
                }.format(bufferName!Component, index, countsName!id));
            }
            else
            {
                mixin(q{
                %s = cast(immutable(ProcessedComponents[%s][]))raw;
                %s = (*pastComponents)[id].counts[].ptr;
                }.format(bufferName!Component, index, countsName!id));
            }
        }

        static if(!noFuture)
        {
            enum futureID = FutureComponent.ComponentTypeID;
            futureComponents_ = &entityManager.future_.components[futureID];
        }

        // Skip dead past entities at the beginning, if any, so front() points to an alive
        // entity (unless we're empty)
        skipDeadEntities();
    }

    /// Get the current past entity.
    Entity front() @safe pure nothrow const @nogc
    {
        return entityAccess_.entity;
    }

    /// Get the EntityAccess data member to pass it to a process() method.
    ref EntityAccess!EntityManager entityAccess() @safe pure nothrow @nogc
    {
        return entityAccess_;
    }

    /// True if we've processed all alive past entities.
    bool empty() @safe pure nothrow @nogc
    {
        // Only live entities are in futureEntities; if we're at the end, the rest of past
        // entities are dead and we don't need to process them.
        return futureEntityIndex_ >= futureEntities_.length;
    }

    /** Move to the next alive past entity (end the range if no alive entities left).
     *
     * Also moves to the next future entity (which is the same as the next alive past
     * entity) and moves to the components of the next entity.
     */
    void popFront() @trusted nothrow
    {
        assert(!empty, "Trying to advance an empty entity range");
        version(assert)
        {
            const past = front().id;
            const future = futureEntities_[futureEntityIndex_].id;
            assert(past == future,
                   "Past:%s and future:%s entity is not the same. Maybe we forgot to skip a "
                   "dead past entity, or we copied a dead entity into future entities, or we "
                   "inserted a new entity elsewhere than the end of future entities."
                   .format(past, future).assumeWontThrow);
            assert(pastComponent!LifeComponent().alive,
                   "Current entity is dead. Likely a bug when calling skipDeadEntities?");
        }

        nextFutureEntity();
        nextPastEntity();

        skipDeadEntities();
    }

    /** Access a past (non-multi) component in the current entity.
     *
     * Params: Component = Type of component to access.
     *
     * Returns: An immutable reference to the past component.
     */
    ref immutable(Component) pastComponent(Component)() @safe nothrow const
        if(!isMultiComponent!Component)
    {
        enum id = Component.ComponentTypeID;
        mixin(q{
        return %s[componentOffsets_[id]];
        }.format(bufferName!Component));
    }

    /** Access past multi components of one type in the current entity.
     *
     * Params: Component = Type of components to access.
     *
     * Returns: An immutable slice to the past components.
     */
    immutable(Component)[] pastComponent(Component)() @system nothrow const
        if(isMultiComponent!Component)
    {
        enum id = Component.ComponentTypeID;
        const offset = componentOffsets_[id];

        mixin(q{
        // Get the number of components in the current past entity.
        const componentCount = %s[entityAccess_.pastEntityIndex];
        // The first component in the current entity is at 'offset'.
        return %s[offset .. offset + componentCount];
        }.format(countsName!id, bufferName!Component));
    }

    /** Get referemce/slice to memory to write future component/s of the current entity to.
     *
     * If FutureComponent is not a MultiComponent, returns a reference. Otherwise returns
     * a slice $(B at least) FutureComponent.maxComponentsPerEntity long.
     *
     * Note that process() may still decide not to write a future component, but we need
     * to provide it with memory to write it if it wants.
     */
    static if(!noFuture)
    auto futureComponent() @trusted nothrow
    {
        enum maxComponents = maxComponentsPerEntity!(FutureComponent);
        // Ensures the needed space is allocated.
        ubyte[] unused = futureComponents_.buffer.forceUncommittedComponentSpace(maxComponents);
        static if(!isMultiComponent!FutureComponent)
        {
            return cast(FutureComponent*)(unused.ptr);
        }
        else
        {
            return (cast(FutureComponent*)(unused.ptr))[0 .. maxComponents];
        }
    }

    /** Specify the number of future components written for the current entity.
     *
     * May be called more than once while processing an entity; the last call must pass
     * the number of components actually written. Must be called at least once.
     *
     * Params: count = Number of components written. Must be 0 or 1 for non-multi components.
     */
    static if(!noFuture)
    void setFutureComponentCount(const ComponentCount count) @safe pure nothrow @nogc
    {
        assert(isMultiComponent!FutureComponent || count <= 1,
               "Component count for a non-multi component can be at most 1");
        futureComponentCount_ = count;
    }

    /// Determine if the current entity contains specified component types.
    bool matchComponents(ComponentTypeIDs...)() @trusted
    {
        // Type IDs of processed component types.
        enum processedIDs = componentIDs!ProcessedComponents;
        // Type IDs of component types we're matching (must be a subset of processedIDs)
        enum sortedIDs    = std.algorithm.sort([ComponentTypeIDs]);
        static assert(sortedIDs.setDifference(processedIDs).empty,
                      "One or more matched component types are not processed by this "
                      "EntityRange.");

        static string matchCode()
        {
            // If the component count for any required component type is 0, the product of
            // multiplying them all is 0. If all are at least 1, the result is true.
            string[] parts;
            foreach(id; ComponentTypeIDs)
            {
                // Component count for this component type will be a member of the product.
                parts ~= q{%s[entityAccess_.pastEntityIndex]}.format(countsName!id);
            }
            return parts.join(" && ");
        }

        // The actual run-time code is here.
        mixin(q{const result = cast(bool)(%s);}.format(matchCode()));
        return result;
    }

private:
    /// Skip (past) dead entities until an alive entity is reached.
    void skipDeadEntities() @trusted pure nothrow @nogc
    {
        // Optimization to avoid repeating some overhead in pastComponent!LifeComponent
        mixin(q{
        immutable(LifeComponent[]) lifeComponents = %s;
        }.format(bufferName!LifeComponent));

        // Skipping dead entities will not make us empty; the last entity, if any, is
        // always alive.
        if(empty) { return; }

        assert(lifeComponents.back.alive, "The last entity must be alive");

        auto lifeOffset = componentOffsets_[LifeComponent.ComponentTypeID];
        while(!lifeComponents[lifeOffset].alive)
        {
            // Each past entity has one life component, alive or not.
            assert(lifeOffset == componentOffsets_[LifeComponent.ComponentTypeID],
                   "lifeOffset must match the actual LifeComponent offset");
            ++lifeOffset;
            assert(!empty, "Skipping dead entities unexpectedly emptied EntityRange");
            nextPastEntity();
        }

        // Unoptimized version:
        // while(!empty && !pastComponent!LifeComponent().alive)
        // {
        //     nextPastEntity();
        // }
    }

    /// Move to the next past entity and its components.
    void nextPastEntity() @system pure nothrow @nogc
    {
        // Generate code for every processed component type to move past the components
        // in this entity.
        foreach(C; ProcessedComponents)
        {
            enum id = cast(size_t)C.ComponentTypeID;
            // Increase offset for this component type by the number of components in the
            // current past entity. The explicit cast to size_t is an optimization (to
            // prevent the compiler from emitting the `cltq` instruction).
            mixin(q{
            componentOffsets_[id] += cast(size_t)%s[entityAccess_.pastEntityIndex];
            }.format(countsName!id));
        }
        entityAccess.nextPastEntity();
    }

    /** Move to the next future entity.
     *
     * Also definitively commits the future components for the current entity.
     */
    void nextFutureEntity() @safe pure nothrow @nogc
    {
        static if(!noFuture)
        {
            // The item in offsets/counts we're setting is uninitialized before we set it.
            futureComponents_.offsets[futureEntityIndex_] = futureComponentOffset_;
            futureComponents_.counts[futureEntityIndex_]  = futureComponentCount_;

            // No need to run this if futureComponentCount_ is 0.
            if(futureComponentCount_ != 0)
            {
                futureComponentOffset_ += futureComponentCount_;
                futureComponents_.buffer.commitComponents(futureComponentCount_);
            }

            // Ease bug detection by setting to an absurd value.
            version(assert) { futureComponentCount_ = ComponentCount.max; }
        }
        ++futureEntityIndex_;
    }

    /** A debug method to print the component counts of processed component types in the
     * current entity.
     */
    void printComponentCounts()
    {
        string[] parts;
        foreach(C; ProcessedComponents)
        {
            enum id = C.ComponentTypeID;
            mixin(q{
            const count = %s[entityAccess_.pastEntityIndex];
            }.format(countsName!id));
            parts ~= "%s: %s".format(id, count);
        }
        return writefln("Component counts (typeid: count):\n%s", parts.join(","));
    }
}

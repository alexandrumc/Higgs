/*****************************************************************************
*
*                      Higgs JavaScript Virtual Machine
*
*  This file is part of the Higgs project. The project is distributed at:
*  https://github.com/maximecb/Higgs
*
*  Copyright (c) 2012-2015, Maxime Chevalier-Boisvert. All rights reserved.
*
*  This software is licensed under the following license (Modified BSD
*  License):
*
*  Redistribution and use in source and binary forms, with or without
*  modification, are permitted provided that the following conditions are
*  met:
*   1. Redistributions of source code must retain the above copyright
*      notice, this list of conditions and the following disclaimer.
*   2. Redistributions in binary form must reproduce the above copyright
*      notice, this list of conditions and the following disclaimer in the
*      documentation and/or other materials provided with the distribution.
*   3. The name of the author may not be used to endorse or promote
*      products derived from this software without specific prior written
*      permission.
*
*  THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED
*  WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
*  MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
*  NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
*  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
*  NOT LIMITED TO PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
*  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
*  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
*  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
*  THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*
*****************************************************************************/

module runtime.object;

import std.stdio;
import std.string;
import std.array;
import std.algorithm;
import std.stdint;
import std.typecons;
import std.bitmanip;
import std.conv;
import ir.ir;
import runtime.vm;
import runtime.layout;
import runtime.string;
import runtime.gc;
import util.id;
import stats;
import options;

/// Minimum object capacity (number of slots)
const uint32_t OBJ_MIN_CAP = 8;

// Static offset for the word array in an object
const size_t OBJ_WORD_OFS = obj_ofs_word(null, 0);

/// Prototype property slot index
const uint32_t PROTO_SLOT_IDX = 0;

/// Function pointer property slot index (closures only)
const uint32_t FPTR_SLOT_IDX = 1;

/// Static offset for the function pointer in a closure object
const size_t FPTR_SLOT_OFS = clos_ofs_word(null, FPTR_SLOT_IDX);

/// Array table slot index (arrays only)
const uint32_t ARRTBL_SLOT_IDX = 1;

/// Static offset for the array table (arrays only)
const size_t ARRTBL_SLOT_OFS = clos_ofs_word(null, ARRTBL_SLOT_IDX);

/// Array length slot index (arrays only)
const uint32_t ARRLEN_SLOT_IDX = 2;

/// Static offset for the array length (arrays only)
const size_t ARRLEN_SLOT_OFS = clos_ofs_word(null, ARRLEN_SLOT_IDX);

/// Property attribute type
alias PropAttr = uint8_t;

/// Property attribute flag bit definitions
const PropAttr ATTR_CONFIGURABLE    = 1 << 0;
const PropAttr ATTR_WRITABLE        = 1 << 1;
const PropAttr ATTR_ENUMERABLE      = 1 << 2;
const PropAttr ATTR_EXTENSIBLE      = 1 << 3;
const PropAttr ATTR_DELETED         = 1 << 4;
const PropAttr ATTR_GETSET          = 1 << 5;

/// Default property attributes
const PropAttr ATTR_DEFAULT = (
    ATTR_CONFIGURABLE   |
    ATTR_WRITABLE       |
    ATTR_ENUMERABLE     |
    ATTR_EXTENSIBLE
);

// Enumerable constant attributes
const PropAttr ATTR_CONST_ENUM = (
    ATTR_ENUMERABLE     |
    ATTR_EXTENSIBLE
);

// Non-enumerable constant attributes
const PropAttr ATTR_CONST_NOT_ENUM = (
    ATTR_EXTENSIBLE
);

/**
Define object-related runtime constants in a VM instance
*/
void defObjConsts(VM vm)
{
    vm.defRTConst!(OBJ_MIN_CAP);

    vm.defRTConst!(PROTO_SLOT_IDX);
    vm.defRTConst!(FPTR_SLOT_IDX);
    vm.defRTConst!(ARRTBL_SLOT_IDX)("ARRTBL_SLOT_IDX");
    vm.defRTConst!(ARRLEN_SLOT_IDX);
    vm.defRTConst!(ARRTBL_SLOT_OFS);
    vm.defRTConst!(ARRLEN_SLOT_OFS);

    vm.defRTConst!(ATTR_CONFIGURABLE);
    vm.defRTConst!(ATTR_WRITABLE);
    vm.defRTConst!(ATTR_ENUMERABLE);
    vm.defRTConst!(ATTR_EXTENSIBLE);
    vm.defRTConst!(ATTR_DELETED);
    vm.defRTConst!(ATTR_GETSET);
    vm.defRTConst!(ATTR_DEFAULT);
    vm.defRTConst!(ATTR_CONST_ENUM);
    vm.defRTConst!(ATTR_CONST_NOT_ENUM);
}

/**
Value type representation
*/
struct ValType
{
    // ValType is at most 2 words long
    static assert (ValType.sizeof <= 16);

    static const ValType ANY = ValType();

    union
    {
        /// Shape (null if unknown)
        ObjShape shape;

        /// IR function pointer
        IRFunction fptr;

        /// Constant value word, if known
        Word word;
    }

    /// Bit field for compact encoding, 32 bits long
    mixin(bitfields!(

        /// Type tag bits, if known
        Tag, "tag", 4,

        /// Type tag known flag
        bool, "tagKnown", 1,

        /// Shape known flag
        bool, "shapeKnown", 1,

        /// Function pointer known flag (closures and fptrs only)
        bool, "fptrKnown", 1,

        /// Constant value known flag
        bool, "valKnown", 1,

        /// Submaximal flag (overflow check elimination)
        bool, "subMax", 1,

        /// Padding bits
        uint, "", 23
    ));

    /// Constructor taking a value pair
    this(ValuePair val)
    {
        assert (
            val.tag < 16,
            "ValuePair ctor, invalid type tag: " ~ to!string(cast(int)val.tag)
        );

        this.tag = val.tag;
        this.tagKnown = true;

        if (isObject(this.tag))
        {
            // Get the object shape
            this.shape = getShape(val.ptr);
            this.shapeKnown = true;
        }
        else if (this.tag is Tag.FUNPTR)
        {
            this.fptr = val.word.funVal;
            this.fptrKnown = true;
        }
        else if (this.tag is Tag.INT32)
        {
            this.word = val.word;
            this.valKnown = true;
        }

        assert (!this.shapeKnown || !this.fptrKnown);
    }

    /// Constructor taking a type tag only
    this(Tag tag)
    {
        assert (
            tag < 16,
            "tag ctor, invalid type tag: " ~ to!string(cast(int)tag) ~ " (" ~ to!string(tag) ~ ")"
        );

        this.tag = tag;
        this.tagKnown = true;

        this.shape = null;
        this.shapeKnown = false;

        this.valKnown = false;
    }

    /// Constructor taking a type tag and shape
    this(Tag tag, ObjShape shape)
    {
        assert (
            tag < 16,
            "tag+shape ctor, invalid type tag: " ~ cast(int)tag
        );

        this.tag = tag;
        this.tagKnown = true;

        this.shape = shape;
        this.shapeKnown = true;

        this.valKnown = false;
    }

    string toString() const
    {
        if (this.tagKnown)
        {
            if (isObject(this.tag))
            {
                return format(
                    "%s (%s)",
                    this.tag,
                    this.shapeKnown? to!string(cast(void*)this.shape):"---"
                );
            }

            if (this.tag is Tag.INT32)
            {
                return format(
                    "%s (%s)",
                    this.tag,
                    this.valKnown? to!string(this.word.int32Val):"---"
                );
            }

            return to!string(this.tag);
        }
        else
        {
            return "---";
        }
    }

    // Comparison operator
    bool opEquals(const ValType that) const
    {
        if (this.tagKnown != that.tagKnown)
            return false;

        if (this.shapeKnown != that.shapeKnown)
            return false;

        if (this.fptrKnown != that.fptrKnown)
            return false;

        if (this.valKnown != that.valKnown)
            return false;

        if (this.tagKnown && this.tag != that.tag)
            return false;

        if ((this.shapeKnown || this.fptrKnown || this.valKnown) &&
            (this.word != that.word))
            return false;

        return true;
    }

    // Hashing operator that does memberwise hashing
    size_t toHash() const nothrow
    {
        size_t h = 0;
        foreach(i, T; typeof(this.tupleof))
        {
            h = h * 33 + typeid(T).getHash(cast(const void*)&this.tupleof[i]);
        }
        return h;
    }

    /**
    Compute the union with another type
    */
    ValType join(ValType that)
    {
        assert (!this.shapeKnown || !this.fptrKnown || !this.valKnown);
        assert (!that.shapeKnown || !that.fptrKnown || !that.valKnown);
        assert (!this.fptrKnown || this.fptr);
        assert (!that.fptrKnown || that.fptr);

        ValType join;

        if (this.tagKnown && that.tagKnown && this.tag is that.tag)
        {
            join.tag = this.tag;
            join.tagKnown = true;
        }
        else
        {
            join.tagKnown = false;
        }

        join.subMax = that.subMax && this.subMax;

        if (this.shapeKnown && that.shapeKnown && this.shape is that.shape)
        {
            join.shape = this.shape;
            join.shapeKnown = true;
        }
        else
        {
            join.shapeKnown = false;
        }

        if (this.fptrKnown && that.fptrKnown && this.fptr is that.fptr)
        {
            join.fptr = this.fptr;
            join.fptrKnown = true;
        }
        else
        {
            join.fptrKnown = false;
        }

        // Known constant, exact value known
        if (this.valKnown && that.valKnown && this.word == that.word)
        {
            join.word = this.word;
            join.valKnown = true;
        }

        return join;
    }

    /**
    Test if this type fits within (is more specific than) another type
    */
    bool isSubType(ValType that)
    {
        return this.join(that) == that;
    }

    /**
    Extract information representable in a property type
    */
    ValType propType()
    {
        ValType that = this;

        // If type tag specialization of shapes is disabled
        if (opts.shape_notagspec)
        {
            // Remove type tag information
            that.tag = cast(Tag)0;
            that.tagKnown = false;
        }

        // Clear the subMax flag
        that.subMax = false;

        // Remove shape information
        if (that.shapeKnown)
        {
            that.shape = null;
            that.shapeKnown = false;
        }

        // Remove constant information
        if (that.valKnown)
        {
            that.word.int64Val = 0;
            that.valKnown = false;
        }

        // If function identity specialization of shapes is disabled
        if (opts.shape_nofptrspec)
        {
            // Remove function pointer information
            that.fptr = null;
            that.fptrKnown = false;
        }
        else
        {
            // If this is a closure with a known shape
            if (this.tagKnown && this.tag is Tag.CLOSURE && this.shapeKnown)
            {
                //writeln("extracting yo");

                // Get the function pointer from the closure
                auto fptrShape = this.shape.getDefShape("__fptr__");
                assert (fptrShape !is null);
                assert (fptrShape.type.fptrKnown);
                that.fptr = fptrShape.type.fptr;
                that.fptrKnown = true;
            }
        }

        assert (!that.shapeKnown || !that.fptrKnown || !that.valKnown);
        assert (!that.fptrKnown || that.fptr);

        return that;
    }
}

/**
Object shape tree representation.
Each shape defines or redefines a property.
*/
class ObjShape
{
    /// Parent shape in the tree
    ObjShape parent;

    /// Property definition transitions, mapped by name, then type
    ObjShape[][ValType][wstring] propDefs;

    /// Cache of property names to defining shapes, to accelerate lookups
    ObjShape[wstring] propCache;

    /// Name of this property, null if array element property
    wstring propName;

    /// Index at which this property is stored
    uint32_t slotIdx;

    /// Unique index number for this shape
    uint32_t shapeIdx;

    /// Value type, may be unknown
    ValType type;

    /// Property attribute flags
    PropAttr attrs;

    /// Table of enumerable properties
    GCRoot enumTbl;

    /// Empty shape constructor
    this()
    {
        // Increment the number of shapes allocated
        stats.numShapes++;

        this.shapeIdx = cast(uint32_t)vm.objShapes.length;
        vm.objShapes ~= this;

        this.parent = null;

        this.propName = null;
        this.type = ValType();
        this.attrs = ATTR_EXTENSIBLE;

        this.slotIdx = uint32_t.max;

        this.enumTbl = GCRoot(NULL);
    }

    /// Property definition constructor
    private this(
        ObjShape parent,
        wstring propName,
        ValType type,
        PropAttr attrs
    )
    {
        // Ensure that this is not a temporary string
        auto strData = cast(rawptr)propName.ptr;
        assert (!inFromSpace(vm, strData) || !inToSpace(vm, strData));

        // Increment the number of shapes allocated
        stats.numShapes++;

        this.shapeIdx = cast(uint32_t)vm.objShapes.length;
        vm.objShapes ~= this;

        this.parent = parent;

        this.propName = propName;
        this.type = type;
        this.attrs = attrs;

        this.slotIdx = parent.slotIdx+1;

        this.enumTbl = GCRoot(NULL);
    }

    ~this()
    {
        //writeln("destroying shape");
    }

    /// Produce a string representation of the shape chain for an object
    override string toString() const
    {
        auto output = appender!string();

        output.put("shape " ~ to!string(shapeIdx) ~ "\n");

        for (auto shape = cast(ObjShape)this; shape.parent !is null; shape = shape.parent)
        {
            output.put(to!string(shape.slotIdx));
            output.put(" : ");
            output.put(shape.propName);
            output.put(" : ");
            output.put(shape.type.toString);

            if (shape.parent.parent !is null)
                output.put("\n");
        }

        return output.data;
    }

    /// Test if this shape has a given attribute
    bool writable() const { return (attrs & ATTR_WRITABLE) != 0; }
    bool configurable() const { return (attrs & ATTR_CONFIGURABLE) != 0; }
    bool enumerable() const { return (attrs & ATTR_ENUMERABLE) != 0; }
    bool extensible() const { return (attrs & ATTR_EXTENSIBLE) != 0; }
    bool deleted() const { return (attrs & ATTR_DELETED) != 0; }
    bool isGetSet() const { return (attrs & ATTR_GETSET) != 0; }

    /**
    Method to define or redefine a property.
    This may fork the shape tree if redefining a property.
    */
    ObjShape defProp(
        wstring propName,
        ValType type,
        PropAttr attrs,
        ObjShape defShape
    )
    {
        // Ensure that this is not a temporary string
        auto strData = cast(rawptr)propName.ptr;
        assert (!inFromSpace(vm, strData) || !inToSpace(vm, strData));

        // Check if a shape object already exists for this definition
        if (propName in propDefs)
        {
            if (type in propDefs[propName])
            {
                foreach (shape; propDefs[propName][type])
                {
                    // If this shape matches, return it
                    if (shape.attrs == attrs)
                        return shape;
                }
            }
        }

        // If this is a new property addition
        if (defShape is null)
        {
            // Create the new shape
            auto newShape = new ObjShape(
                defShape? defShape:this,
                propName,
                type,
                attrs
            );

            // Add it to the property definitions
            propDefs[propName][type] ~= newShape;
            assert (propDefs[propName][type].length > 0);

            return newShape;
        }

        // This is redefinition of an existing property
        // Assemble the list of properties added
        // after the original definition shape
        ObjShape[] shapes;
        for (auto shape = this; shape !is defShape; shape = shape.parent)
        {
            assert (shape !is null);
            shapes ~= shape;
        }

        // Define the property with the same parent
        // as the original shape
        auto curParent = defShape.parent.defProp(
            propName,
            type,
            attrs,
            null
        );

        // Redefine all the intermediate properties
        foreach_reverse (shape; shapes)
        {
            curParent = curParent.defProp(
                shape.propName,
                shape.type,
                shape.attrs,
                null
            );
        }

        // Add the last added shape to the property definitions
        propDefs[propName][type] ~= curParent;
        assert (propDefs[propName][type].length > 0);

        return curParent;
    }

    /**
    Get the shape defining a given property
    Warning: the input string may be a temporary slice into the JS heap
    */
    ObjShape getDefShape(wstring propName)
    {
        // If there is a cached shape for this property name, return it
        auto cached = propCache.get(propName, this);
        if (cached !is this)
           return cached;

        // Copy the string to avoid storing references to the JS heap
        propName = propName.dup;

        // For each shape going down the tree, excluding the root
        for (auto shape = this; shape.parent !is null; shape = shape.parent)
        {
            // If the name matches
            if (propName == shape.propName && !shape.deleted)
            {
                // Cache the shape found for this property name
                propCache[propName] = shape;

                // Return the shape
                return shape;
            }
        }

        // Cache that the property was not found
        propCache[propName] = null;

        // Root shape reached, property not found
        return null;
    }

    /**
    Generate a table of names enumerable properties for objects of this shape
    */
    refptr genEnumTbl()
    {
        if (enumTbl.ptr)
            return enumTbl.ptr;

        // Number of enumerable properties
        auto numEnum = 0;

        // For each shape going down the tree, excluding the root
        for (auto shape = this; shape.parent !is null; shape = shape.parent)
        {
            // If this shape is enumerable
            if (shape.enumerable)
                numEnum++;
        }

        // If there are no enumerable properties
        if (numEnum is 0)
        {
            // Produce an empty property enumeration table
            enumTbl = ValuePair(arrtbl_alloc(vm, 0), Tag.REFPTR);
            return enumTbl.ptr;
        }

        // Allocate the table
        auto numEntries = 2 * (this.slotIdx + 1);
        enumTbl = ValuePair(arrtbl_alloc(vm, numEntries), Tag.REFPTR);

        // For each shape going down the tree, excluding the root
        for (auto shape = this; shape.parent !is null; shape = shape.parent)
        {
            ValuePair name = NULL;
            ValuePair attr = ValuePair(0);

            // If this property is enumerable
            if (shape.enumerable)
            {
                // Get a JS string for the property name
                name.word.ptrVal = getString(vm, shape.propName);
                name.tag = Tag.STRING;

                // Get the property attributes
                attr.word.uint64Val = shape.attrs;
            }

            // Write the property name
            auto nameIdx = 2 * shape.slotIdx;
            arrtbl_set_word(enumTbl.ptr, nameIdx, name.word.uint64Val);
            arrtbl_set_tag (enumTbl.ptr, nameIdx, name.tag);

            // Write the property attributes
            auto attrIdx = nameIdx + 1;
            arrtbl_set_word(enumTbl.ptr, attrIdx, attr.word.uint64Val);
            arrtbl_set_tag (enumTbl.ptr, attrIdx, attr.tag);
        }

        assert (vm.inFromSpace(enumTbl.ptr));
        return enumTbl.ptr;
    }
}

ValuePair newObj(
    ValuePair proto,
    uint32_t initCap = OBJ_MIN_CAP
)
{
    assert (initCap >= OBJ_MIN_CAP);

    // Create a root for the prototype object
    auto protoObj = GCRoot(proto);

    // Allocate the object
    auto objPtr = obj_alloc(vm, initCap);
    auto objPair = ValuePair(objPtr, Tag.OBJECT);

    obj_set_shape_idx(objPtr, vm.emptyShape.shapeIdx);

    defConst(objPair, "__proto__"w, protoObj.pair);

    return objPair;
}

ValuePair newClos(
    ValuePair proto,
    uint32_t allocNumCells,
    IRFunction fun
)
{
    // Create a root for the prototype object
    auto protoObj = GCRoot(proto);

    // Register this function in the function reference set
    vm.funRefs[cast(void*)fun] = fun;

    // Allocate the closure object
    auto objPtr = clos_alloc(vm, OBJ_MIN_CAP, allocNumCells);
    auto objPair = ValuePair(objPtr, Tag.CLOSURE);

    obj_set_shape_idx(objPair.word.ptrVal, vm.emptyShape.shapeIdx);

    defConst(objPair, "__proto__"w, protoObj.pair);
    defConst(objPair, "__fptr__"w, ValuePair(fun));

    return objPair;
}

/// Get the shape of an object
ObjShape getShape(refptr objPtr)
{
    auto shapeIdx = obj_get_shape_idx(objPtr);
    return vm.objShapes[shapeIdx];
}

/// Get the function pointer from a closure object
IRFunction getFunPtr(refptr closPtr)
{
    return cast(IRFunction)cast(refptr)clos_get_word(closPtr, FPTR_SLOT_IDX);
}

refptr getArrTbl(refptr arrPtr)
{
    return cast(refptr)clos_get_word(arrPtr, ARRTBL_SLOT_IDX);
}

void setArrTbl(refptr arrPtr, refptr tblPtr)
{
    obj_set_word(arrPtr, ARRTBL_SLOT_IDX, cast(uint64_t)tblPtr);
    obj_set_tag(arrPtr, ARRTBL_SLOT_IDX, Tag.REFPTR);
}

uint32_t getArrLen(refptr arrPtr)
{
    return cast(uint32_t)clos_get_word(arrPtr, ARRLEN_SLOT_IDX);
}

void setArrLen(refptr arrPtr, uint32_t len)
{
    clos_set_word(arrPtr, ARRLEN_SLOT_IDX, len);
}

ValuePair getSlotPair(refptr objPtr, uint32_t slotIdx)
{
    auto pWord = Word.uint64v(obj_get_word(objPtr, slotIdx));
    auto pType = cast(Tag)obj_get_tag(objPtr, slotIdx);
    return ValuePair(pWord, pType);
}

void setSlotPair(refptr objPtr, uint32_t slotIdx, ValuePair val)
{
    obj_set_word(objPtr, slotIdx, val.word.uint64Val);
    obj_set_tag(objPtr, slotIdx, val.tag);
}

ValuePair getProp(ValuePair obj, wstring propStr)
{
    // Get the shape from the object
    auto objShape = getShape(obj.word.ptrVal);
    assert (objShape !is null);

    // Find the shape defining this property (if it exists)
    auto defShape = objShape.getDefShape(propStr);

    // If the property is defined
    if (defShape !is null)
    {
        uint32_t slotIdx = defShape.slotIdx;
        auto objCap = obj_get_cap(obj.word.ptrVal);

        if (slotIdx < objCap)
        {
            return getSlotPair(obj.word.ptrVal, slotIdx);
        }
        else
        {
            auto extTbl = obj_get_next(obj.word.ptrVal);
            assert (slotIdx < obj_get_cap(extTbl));
            return getSlotPair(extTbl, slotIdx);
        }
    }

    // Get the prototype pointer
    auto proto = getProp(obj, "__proto__"w);

    // If the prototype is null, produce the undefined constant
    if (proto is NULL)
        return UNDEF;

    // Do a recursive lookup on the prototype
    return getProp(
        proto,
        propStr
    );
}

bool setProp(
    ValuePair objPair,
    wstring propStr,
    ValuePair valPair,
    PropAttr defAttrs = ATTR_DEFAULT
)
{
    // A property cannot have no attributes
    assert (defAttrs !is 0);

    static ValuePair allocExtTbl(VM vm, refptr obj, uint32_t extCap)
    {
        // Get the object layout type
        auto header = obj_get_header(obj);

        // Switch on the layout type
        switch (header)
        {
            case LAYOUT_OBJ:
            return ValuePair(obj_alloc(vm, extCap), Tag.OBJECT);

            case LAYOUT_ARR:
            return ValuePair(arr_alloc(vm, extCap), Tag.ARRAY);

            case LAYOUT_CLOS:
            auto numCells = clos_get_num_cells(obj);
            return ValuePair(clos_alloc(vm, extCap, numCells), Tag.CLOSURE);

            default:
            assert (false, "unhandled object type");
        }
    }

    auto obj = GCRoot(objPair);
    auto val = GCRoot(valPair);

    assert (
        valPair.tag < 16,
        "setProp, invalid tag=" ~ to!string(cast(int)val.tag) ~
        ", propName=" ~ to!string(propStr)
    );

    // Create a type object for the value
    auto valType = ValType(valPair).propType;

    // Get the shape from the object
    auto objShape = getShape(obj.word.ptrVal);
    assert (objShape !is null);

    // Find the shape defining this property (if it exists)
    auto defShape = objShape.getDefShape(propStr);

    // If the property is not already defined
    if (defShape is null)
    {
        // If the object is not extensible, do nothing
        if (!objShape.extensible)
        {
            //writeln("rejecting write for ", propStr);
            return false;
        }

        // Create a new shape for the property
        defShape = objShape.defProp(
            propStr,
            valType,
            defAttrs,
            null
        );

        // Set the new shape for the object
        obj_set_shape_idx(obj.ptr, defShape.shapeIdx);
    }
    else
    {
        // If the property is not writable, do nothing
        if (!defShape.writable)
        {
            //writeln("redefining constant: ", propStr);
            return false;
        }

        // If the value type doesn't match the shape type
        if (!valType.isSubType(defShape.type))
        {
            // Number of shape changes due to a type mismatch
            ++stats.numShapeFlips;
            if (objPair == vm.globalObj)
                ++stats.numShapeFlipsGlobal;

            //writeln(defShape.type.tag, " ==> ", valType.tag);

            // Change the defining shape to match the value type
            objShape = objShape.defProp(
                propStr,
                valType,
                defAttrs,
                defShape
            );

            // Set the new shape for the object
            obj_set_shape_idx(obj.ptr, objShape.shapeIdx);

            // Find the shape defining this property
            defShape = objShape.getDefShape(propStr);
            assert (defShape !is null);
        }
    }

    uint32_t slotIdx = defShape.slotIdx;

    // Get the number of slots in the object
    auto objCap = obj_get_cap(obj.ptr);
    assert (objCap > 0);

    // If the slot is within the object
    if (slotIdx < objCap)
    {
        // Set the value and its type in the object
        setSlotPair(obj.ptr, slotIdx, val.pair);
    }

    // The property is past the object's capacity
    else 
    {
        // Get the extension table pointer
        auto extTbl = GCRoot(obj_get_next(obj.ptr), Tag.OBJECT);

        // If the extension table isn't yet allocated
        if (extTbl.ptr is null)
        {
            auto extCap = 2 * objCap;
            extTbl = allocExtTbl(vm, obj.ptr, extCap);
            obj_set_next(obj.ptr, extTbl.ptr);
        }

        auto extCap = obj_get_cap(extTbl.ptr);

        // If the extension table isn't big enough
        if (slotIdx >= extCap)
        {
            auto newExtCap = 2 * extCap;
            auto newExtTbl = allocExtTbl(vm, obj.ptr, newExtCap);

            // Copy over the property words and types
            for (uint32_t i = objCap; i < extCap; ++i)
                setSlotPair(newExtTbl.ptr, i, getSlotPair(extTbl.ptr, i));

            extTbl = newExtTbl;
            obj_set_next(obj.ptr, extTbl.ptr);
        }

        // Set the value and its type in the extension table
        setSlotPair(extTbl.ptr, slotIdx, val.pair);
    }

    // Write successful
    return true;
}

/**
Define a constant on an object
*/
bool defConst(
    ValuePair objPair,
    wstring propStr,
    ValuePair valPair,
    bool enumerable = false
)
{
    auto objShape = getShape(objPair.word.ptrVal);
    assert (objShape !is null);

    auto defShape = objShape.getDefShape(propStr);

    // If the property is already defined, stop
    if (defShape !is null)
    {
        return false;
    }

    setProp(
        objPair,
        propStr,
        valPair,
        enumerable?
        ATTR_CONST_ENUM:
        ATTR_CONST_NOT_ENUM
    );

    return true;
}

/**
Set the attributes for a given property
*/
bool setPropAttrs(
    ValuePair obj,
    ObjShape defShape,
    PropAttr attrs
)
{
    // Get the shape from the object
    auto objShape = getShape(obj.word.ptrVal);
    assert (objShape !is null);

    assert (defShape !is null);

    // Redefine the property
    auto newShape = objShape.defProp(
        defShape.propName,
        defShape.type,
        attrs,
        defShape
    );

    // Set the new object shape
    obj_set_shape_idx(obj.word.ptrVal, newShape.shapeIdx);

    // Operation successful
    return true;
}


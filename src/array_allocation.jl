module array_allocation

export allocate_float, allocate_int, allocate_complex, allocate_bool, allocate_shared

using ..type_definitions: mk_float, mk_int
using ..communication: allocate_shared

# allocate array with dimensions given by dims and entries of type Bool
function allocate_bool(dims...)
    return array = Array{Bool}(undef, dims...)
end
# variant where array is in shared memory for all processors in the 'block'
function allocate_shared_bool(dims...)
    return array = allocate_shared(Bool, dims)
end

# allocate 1d array with dimensions given by dims and entries of type mk_int
function allocate_int(dims)
    return array = Array{mk_int}(undef, dims...)
end
# variant where array is in shared memory for all processors in the 'block'
function allocate_shared_int(dims...)
    return array = allocate_shared(mk_int, dims)
end

# allocate array with dimensions given by dims and entries of type mk_float
function allocate_float(dims...)
    return array = Array{mk_float}(undef, dims...)
end
# variant where array is in shared memory for all processors in the 'block'
function allocate_shared_float(dims...)
    return array = allocate_shared(mk_float, dims)
end

# allocate 1d array with dimensions given by dims and entries of type Complex{mk_float}
function allocate_complex(dims...)
    return array = Array{Complex{mk_float}}(undef, dims...)
end
# variant where array is in shared memory for all processors in the 'block'
function allocate_shared_complex(dims...)
    return array = allocate_shared(Complex{mk_float}, dims)
end

end

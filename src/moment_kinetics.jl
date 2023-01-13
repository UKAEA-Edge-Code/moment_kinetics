"""
"""
module moment_kinetics

export run_moment_kinetics

using MPI

# Include submodules from other source files
# Note that order of includes matters - things used in one module must already
# be defined
include("command_line_options.jl")
include("debugging.jl")
include("type_definitions.jl")
include("communication.jl")
include("moment_kinetics_structs.jl")
include("looping.jl")
include("array_allocation.jl")
include("interpolation.jl")
include("clenshaw_curtis.jl")
include("chebyshev.jl")
include("finite_differences.jl")
include("quadrature.jl")
include("calculus.jl")
include("derivatives.jl")
include("input_structs.jl")
include("coordinates.jl")
include("file_io.jl")
include("velocity_moments.jl")
include("velocity_grid_transforms.jl")
include("em_fields.jl")
include("bgk.jl")
include("manufactured_solns.jl") # MRH Here?
include("initial_conditions.jl")
#include("semi_lagrange.jl")
include("advection.jl")
include("vpa_advection.jl")
include("z_advection.jl")
include("r_advection.jl")
include("vperp_advection.jl")
include("neutral_advection.jl")
include("charge_exchange.jl")
include("ionization.jl")
include("continuity.jl")
include("energy_equation.jl")
include("force_balance.jl")
include("source_terms.jl")
include("numerical_dissipation.jl")
include("time_advance.jl")

include("moment_kinetics_input.jl")
include("scan_input.jl")

include("load_data.jl")
include("analysis.jl")
include("post_processing_input.jl")
include("post_processing.jl")
include("plot_MMS_sequence.jl")
include("plot_sequence.jl")

using TimerOutputs
using Dates

using .file_io: setup_file_io, finish_file_io
using .file_io: write_data_to_ascii
using .file_io: write_moments_data_to_binary, write_dfns_data_to_binary
using .command_line_options: get_options
using .communication
using .coordinates: define_coordinate
using .debugging
using .initial_conditions: init_pdf_and_moments
using .looping
using .looping: debug_setup_loop_ranges_split_one_combination!
using .moment_kinetics_input: mk_input, read_input_file, run_type, performance_test
using .time_advance: setup_time_advance!, time_advance!

@debug_detect_redundant_block_synchronize using ..communication: debug_detect_redundant_is_active

"""
main function that contains all of the content of the program
"""
function run_moment_kinetics(to::TimerOutput, input_dict=Dict())
    mk_state = nothing
    try
        # set up all the structs, etc. needed for a run
        mk_state = setup_moment_kinetics(input_dict)

        # solve the 1+1D kinetic equation to advance f in time by nstep time steps
        if run_type == performance_test
            @timeit to "time_advance" time_advance!(mk_state...)
        else
            time_advance!(mk_state...)
        end

        # clean up i/o and communications
        # last 3 elements of mk_state are ascii_io, io_moments, and io_dfns
        cleanup_moment_kinetics!(mk_state[end-2:end]...)

        if block_rank[] == 0 && run_type == performance_test
            # Print the timing information if this is a performance test
            display(to)
            println()
        end
    catch e
        # Stop code from hanging when running on multiple processes if only one of them
        # throws an error
        if global_size[] > 1
            println("$(typeof(e)) on process $(global_rank[]):")
            showerror(stdout, e)
            display(stacktrace(catch_backtrace()))
            flush(stdout)
            flush(stderr)
            MPI.Abort(comm_world, 1)
        else
            # Error almost certainly occured before cleanup. If running in serial we can
            # still finalise file I/O
            cleanup_moment_kinetics!(mk_state[end-2:end]...)
        end

        rethrow(e)
    end

    return nothing
end

"""
overload which takes a filename and loads input
"""
function run_moment_kinetics(to::TimerOutput, input_filename::String)
    return run_moment_kinetics(to, read_input_file(input_filename))
end

"""
overload with no TimerOutput arguments
"""
function run_moment_kinetics(input)
    return run_moment_kinetics(TimerOutput(), input)
end

"""
overload which gets the input file name from command line arguments
"""
function run_moment_kinetics()
    inputfile = get_options()["inputfile"]
    if inputfile == nothing
        run_moment_kinetics(Dict())
    else
        run_moment_kinetics(inputfile)
    end
end

"""
Perform all the initialization steps for a run.

`debug_loop_type` and `debug_loop_parallel_dims` are used to force specific set ups for
parallel loop ranges, and are only used by the tests in `debug_test/`.
"""
function setup_moment_kinetics(input_dict::Dict;
        debug_loop_type::Union{Nothing,NTuple{N,Symbol} where N}=nothing,
        debug_loop_parallel_dims::Union{Nothing,NTuple{N,Symbol} where N}=nothing)

    # Set up MPI
    initialize_comms!()

    input = mk_input(input_dict)
    # obtain input options from moment_kinetics_input.jl
    # and check input to catch errors
    io_input, evolve_moments,
        t_input, z_input, r_input,
        vpa_input, vperp_input, gyrophase_input,
        vz_input, vr_input, vzeta_input,
        composition, species, collisions,
        geometry, drive_input, num_diss_params  = input
    # initialize z grid and write grid point locations to file
    z = define_coordinate(z_input)
    # initialize r grid and write grid point locations to file
    r = define_coordinate(r_input)
    # initialize vpa grid and write grid point locations to file
    vpa = define_coordinate(vpa_input)
    # initialize vperp grid and write grid point locations to file
    vperp = define_coordinate(vperp_input)
    # initialize gyrophase grid and write grid point locations to file
    gyrophase = define_coordinate(gyrophase_input)
    # initialize vz grid and write grid point locations to file
    vz = define_coordinate(vz_input)
    # initialize vr grid and write grid point locations to file
    vr = define_coordinate(vr_input)
    # initialize vr grid and write grid point locations to file
    vzeta = define_coordinate(vzeta_input)
    # Create loop range variables for shared-memory-parallel loops
    if composition.n_neutral_species == 0
        n_neutral_loop_size = 1 # Need this to have looping setup. Avoid neutral loops with if statements.
    else
        n_neutral_loop_size = composition.n_neutral_species
    end
    if debug_loop_type === nothing
        # Non-debug case used for all simulations
        looping.setup_loop_ranges!(block_rank[], block_size[];
                                   s=composition.n_ion_species, sn=n_neutral_loop_size,
                                   r=r.n, z=z.n, vperp=vperp.n, vpa=vpa.n,
                                   vzeta=vzeta.n, vr=vr.n, vz=vz.n)
    else
        if debug_loop_parallel_dims === nothing
            error("debug_loop_parallel_dims must not be `nothing` when debug_loop_type "
                  * "is not `nothing`.")
        end
        # Debug initialisation only used by tests in `debug_test/`
        debug_setup_loop_ranges_split_one_combination!(
            block_rank[], block_size[], debug_loop_type, debug_loop_parallel_dims...;
            s=composition.n_ion_species, sn=n_neutral_loop_size, r=r.n, z=z.n,
            vperp=vperp.n, vpa=vpa.n, vzeta=vzeta.n, vr=vr.n, vz=vz.n)
    end
    # initialize f and the lowest three v-space moments (density, upar and ppar),
    # each of which may be evolved separately depending on input choices.
    pdf, moments, boundary_distributions = init_pdf_and_moments(vz, vr, vzeta, vpa, vperp, z, r, composition, geometry, species, t_input.n_rk_stages, evolve_moments, t_input.use_manufactured_solns_for_init)
    # initialize time variable
    code_time = 0.
    # create arrays and do other work needed to setup
    # the main time advance loop -- including normalisation of f by density if requested

    moments, fields, spectral_objects, advect_objects,
    scratch, advance, scratch_dummy, manufactured_source_list = setup_time_advance!(pdf, vz, vr, vzeta, vpa, vperp, z, r, composition,
        drive_input, moments, t_input, collisions, species, geometry, boundary_distributions, num_diss_params)
    # setup i/o
    ascii_io, io_moments, io_dfns = setup_file_io(io_input, vz, vr, vzeta, vpa, vperp, z, r, composition, collisions)
    # write initial data to ascii files
    write_data_to_ascii(moments, fields, vpa, vperp, z, r, code_time, composition.n_ion_species, composition.n_neutral_species, ascii_io)
    # write initial data to binary file (netcdf)

    write_moments_data_to_binary(moments, fields, code_time, composition.n_ion_species,
        composition.n_neutral_species, io_moments, 1)
    write_dfns_data_to_binary(pdf.charged.unnorm, pdf.neutral.unnorm, code_time,
        composition.n_ion_species, composition.n_neutral_species, io_dfns, 1)

    begin_s_r_z_vperp_region()

    return pdf, scratch, code_time, t_input, vz, vr, vzeta, vpa, vperp, gyrophase, z, r,
           moments, fields, spectral_objects, advect_objects,
           composition, collisions, geometry, boundary_distributions,
           num_diss_params, advance, scratch_dummy, manufactured_source_list,
           ascii_io, io_moments, io_dfns
end

"""
Clean up after a run
"""
function cleanup_moment_kinetics!(ascii_io::Union{file_io.ascii_ios,Nothing},
                                  io_moments::Union{file_io.io_moments_info,Nothing},
                                  io_dfns::Union{file_io.io_dfns_info,Nothing})
    @debug_detect_redundant_block_synchronize begin
        # Disable check for redundant _block_synchronize() during finalization, as this
        # only runs once so any failure is not important.
        debug_detect_redundant_is_active[] = false
    end

    begin_serial_region()

    # finish i/o
    finish_file_io(ascii_io, io_moments, io_dfns)

    @serial_region begin
        if global_rank[] == 0
            println("finished file io         ",
               Dates.format(now(), dateformat"H:MM:SS"))
        end
    end

    # clean up MPI objects
    finalize_comms!()

    return nothing
end

end

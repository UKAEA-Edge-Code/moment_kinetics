# add the current directory to the path where the code looks for external modules
push!(LOAD_PATH, ".")

using TimerOutputs

using file_io: setup_file_io, finish_file_io
using file_io: write_data_to_ascii, write_data_to_binary
using chebyshev: setup_chebyshev_pseudospectral
using coordinates: define_coordinate, write_coordinate
using source_terms: setup_source, update_boundary_indices!
using semi_lagrange: setup_semi_lagrange
using vpa_advection: vpa_advection!, update_speed_vpa!
using z_advection: z_advection!, update_speed_z!
using velocity_moments: setup_moments
using em_fields: setup_em_fields, update_phi!
using initial_conditions: init_f
using initial_conditions: enforce_z_boundary_condition!

using moment_kinetics_input: run_name
using moment_kinetics_input: z_input, vpa_input
using moment_kinetics_input: nstep, dt, nwrite, use_semi_lagrange
using moment_kinetics_input: check_input
using moment_kinetics_input: performance_test

to1 = TimerOutput()
to2 = TimerOutput()

# main function that contains all of the content of the program
function moment_kinetics(to)
    # check input options to catch errors
    check_input()
    # initialize z grid and write grid point locations to file
    z = define_coordinate(z_input)
    write_coordinate(z, run_name, "zgrid")
    # initialize vpa grid and write grid point locations to file
    vpa = define_coordinate(vpa_input)
    write_coordinate(vpa, run_name, "vpa")
    # initialize f(z)
    ff, ff_scratch = init_f(z, vpa)
    # initialize time variable
    code_time = 0.
    # create arrays and do other work needed to setup
    # the main time advance loop
    z_spectral, vpa_spectral, moments, fields, z_source, vpa_source,
        z_SL, vpa_SL = setup_time_advance!(ff, z, vpa)
    # setup i/o
    io, cdf = setup_file_io(run_name, z, vpa)
    # write initial data to ascii files
    write_data_to_ascii(ff, moments, fields, z, vpa, code_time, io)
    # write initial data to binary file (netcdf)
    write_data_to_binary(ff, moments, fields, code_time, cdf, 1)
    # solve the 1+1D kinetic equation to advance f in time by nstep time steps
    if performance_test
        @timeit to "time_advance" time_advance!(ff, ff_scratch, code_time, z, vpa,
            z_spectral, vpa_spectral, moments,
            fields, z_source, vpa_source, z_SL, vpa_SL, io, cdf)
    else
        time_advance!(ff, ff_scratch, code_time, z, vpa,
            z_spectral, vpa_spectral, moments,
            fields, z_source, vpa_source, z_SL, vpa_SL, io, cdf)
    end
    # finish i/o
    finish_file_io(io, cdf)
    return nothing
end
# create arrays and do other work needed to setup
# the main time advance loop.
# this includes creating and populating structs
# for Chebyshev transforms, velocity space moments,
# EM fields, semi-Lagrange treatment, and source terms
function setup_time_advance!(ff, z, vpa)
    # create structure z_source whose members are the arrays needed to compute
    # the source(s) appearing in the split part of the GK equation dealing
    # with advection in z
    z_source = setup_source(z.n, vpa.n)
    # initialise the z advection speed
    update_speed_z!(z_source, vpa, z)
    # initialise the upwind/downwind boundary indices in z
    update_boundary_indices!(z_source)
    # enforce prescribed boundary condition in z on the distribution function f
    enforce_z_boundary_condition!(ff, z.bc, vpa, z_source)
    if z.discretization == "chebyshev_pseudospectral"
        # create arrays needed for explicit Chebyshev pseudospectral treatment in vpa
        # and create the plans for the forward and backward fast Chebyshev transforms
        z_spectral = setup_chebyshev_pseudospectral(z)
    else
        # create dummy Bool variable to return in place of the above struct
        z_spectral = false
    end
    if vpa.discretization == "chebyshev_pseudospectral"
        # create arrays needed for explicit Chebyshev pseudospectral treatment in vpa
        # and create the plans for the forward and backward fast Chebyshev transforms
        vpa_spectral = setup_chebyshev_pseudospectral(vpa)
    else
        # create dummy Bool variable to return in place of the above struct
        vpa_spectral = false
    end
    # pass a subarray of ff (its value at the previous time level)
    # and allocate/initialize the velocity space moments needed for advancing
    # the kinetic equation coupled to fluid equations
    # the resulting moments are returned in the structure "moments"
    moments = setup_moments(ff, vpa, z.n)
    # pass a subarray of ff (its value at the previous time level)
    # and create the "fields" structure that contains arrays
    # for the electrostatic potential phi and eventually the electromagnetic fields
    fields = setup_em_fields(z.n)
    # initialize the electrostatic potential
    update_phi!(fields.phi, moments, ff, vpa, z.n)
    # create structure vpa_source whose members are the arrays needed to compute
    # the source(s) appearing in the split part of the GK equation dealing
    # with advection in vpa
    vpa_source = setup_source(vpa.n, z.n)
    # initialise the vpa advection speed
    update_speed_vpa!(vpa_source, fields.phi, moments, ff, vpa, z.n)
    # initialise the upwind/downwind boundary indices in vpa
    update_boundary_indices!(vpa_source)
    # create an array of structures containing the arrays needed for the semi-Lagrange
    # solve and initialize the characteristic speed and departure indices
    # so that the code can gracefully run without using the semi-Lagrange
    # method if the user specifies this
    z_SL = setup_semi_lagrange(z.n, vpa.n)
    vpa_SL = setup_semi_lagrange(vpa.n, z.n)
    return z_spectral, vpa_spectral, moments, fields, z_source, vpa_source, z_SL, vpa_SL
end
# solve ∂f/∂t + v(z,t)⋅∂f/∂z + dvpa/dt ⋅ ∂f/∂vpa= 0
# define approximate characteristic velocity
# v₀(z)=vⁿ(z) and take time derivative along this characteristic
# df/dt + δv⋅∂f/∂z = 0, with δv(z,t)=v(z,t)-v₀(z)
# for prudent choice of v₀, expect δv≪v so that explicit
# time integrator can be used without severe CFL condition
function time_advance!(ff, ff_scratch, t, z, vpa, z_spectral, vpa_spectral,
    moments, fields, z_source, vpa_source, z_SL, vpa_SL, io, cdf)
    # main time advance loop
    iwrite = 2
    for i ∈ 1:nstep
        # z_advection! advances the operator-split 1D advection equation in z
        if z.discretization == "chebyshev_pseudospectral"
            z_advection!(ff, ff_scratch, z_SL, z_source, z, vpa, use_semi_lagrange, dt, z_spectral)
        elseif z.discretization == "finite_difference"
            z_advection!(ff, ff_scratch, z_SL, z_source, z, vpa, use_semi_lagrange, dt)
        end
        # reset "xx.updated" flags to false since ff has been updated
        # and the corresponding moments have not
        moments.dens_updated = false ; moments.ppar_updated = false
        # vpa_advection! advances the operator-split 1D advection equation in vpa
        if vpa.discretization == "chebyshev_pseudospectral"
            vpa_advection!(ff, ff_scratch, fields.phi, moments, vpa_SL, vpa_source,
                vpa, z.n, use_semi_lagrange, dt, vpa_spectral, z_spectral)
        elseif vpa.discretization == "finite_difference"
            vpa_advection!(ff, ff_scratch, fields.phi, moments, vpa_SL, vpa_source,
                vpa, z.n, use_semi_lagrange, dt)
        end
        # update the time
        t += dt
        # write ff to file every nwrite time steps
        if mod(i,nwrite) == 0
            write_data_to_ascii(ff, moments, fields, z, vpa, t, io)
            write_data_to_binary(ff, moments, fields, t, cdf, iwrite)
            iwrite += 1
        end
    end
    return nothing
end

if performance_test
    @timeit to1 "moment_kinetics 1" moment_kinetics(to1)
    show(to1)
    println()
    @timeit to2 "moment_kinetics 1" moment_kinetics(to2)
    show(to2)
    println()
else
    moment_kinetics(to1)
end

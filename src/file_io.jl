"""
"""
module file_io

export input_option_error
export open_output_file, open_ascii_output_file
export setup_file_io, finish_file_io
export write_moments_data_to_binary
export write_data_to_ascii
export write_data_to_netcdf, write_data_to_hdf5

using ..communication
using ..coordinates: coordinate
using ..debugging
using ..input_structs
using ..looping
using ..moment_kinetics_structs: scratch_pdf, em_fields_struct
using ..type_definitions: mk_float, mk_int

@debug_shared_array using ..communication: DebugMPISharedArray

"""
structure containing the various input/output streams
"""
struct ascii_ios{T <: Union{IOStream,Nothing}}
    # corresponds to the ascii file to which the distribution function is written
    #ff::T
    # corresponds to the ascii file to which velocity space moments of the
    # distribution function such as density and pressure are written
    moments_ion::T
    moments_electron::T
    moments_neutral::T
    # corresponds to the ascii file to which electromagnetic fields
    # such as the electrostatic potential are written
    fields::T
end

"""
structure containing the data/metadata needed for binary file i/o
moments & fields only
"""
struct io_moments_info{Tfile, Ttime, Tphi, Tmomi, Tmomn}
     # file identifier for the binary file to which data is written
    fid::Tfile
    # handle for the time variable
    time::Ttime
    # handle for the electrostatic potential variable
    phi::Tphi
    # handle for the radial electric field variable
    Er::Tphi
    # handle for the z electric field variable
    Ez::Tphi
    # handle for the ion species density
    density::Tmomi
    # handle for the ion species parallel flow
    parallel_flow::Tmomi
    # handle for the ion species parallel pressure
    parallel_pressure::Tmomi
    # handle for the ion species parallel heat flux
    parallel_heat_flux::Tmomi
    # handle for the ion species thermal speed
    thermal_speed::Tmomi

    # handle for the electron species density
    electron_density::Tphi
    # handle for the electron species parallel flow
    electron_parallel_flow::Tphi
    # handle for the electron species parallel pressure
    electron_parallel_pressure::Tphi
    # handle for the electron species parallel heat flux
    electron_parallel_heat_flux::Tphi
    # handle for the electron species thermal speed
    electron_thermal_speed::Tphi

    # handle for the neutral species density
    density_neutral::Tmomn
    uz_neutral::Tmomn
    pz_neutral::Tmomn
    qz_neutral::Tmomn
    thermal_speed_neutral::Tmomn

    # Use parallel I/O?
    parallel_io::Bool
 end

"""
structure containing the data/metadata needed for binary file i/o
distribution function data only
"""
struct io_dfns_info{Tfile, Tfi, Tfn, Tmoments}
    # file identifier for the binary file to which data is written
    fid::Tfile
    # handle for the ion species distribution function variable
    f::Tfi
    # handle for the neutral species distribution function variable
    f_neutral::Tfn

    # Use parallel I/O?
    parallel_io::Bool

    # Handles for moment variables
    io_moments::Tmoments
end

"""
    io_has_parallel(Val(binary_format))

Test if the backend supports parallel I/O.

`binary_format` should be one of the values of the `binary_format_type` enum
"""
function io_has_parallel() end

"""
open the necessary output files
"""
function setup_file_io(io_input, boundary_distributions, vz, vr, vzeta, vpa, vperp, z, r,
                       composition, collisions, evolve_density, evolve_upar, evolve_ppar,
                       input_dict)
    begin_serial_region()
    @serial_region begin
        # Only read/write from first process in each 'block'

        # check to see if output_dir exists in the current directory
        # if not, create it
        isdir(io_input.output_dir) || mkdir(io_input.output_dir)
        out_prefix = string(io_input.output_dir, "/", io_input.run_name)

        if io_input.ascii_output
            ff_io = open_ascii_output_file(out_prefix, "f_vs_t")
            mom_ion_io = open_ascii_output_file(out_prefix, "moments_ion_vs_t")
            mom_eon_io = open_ascii_output_file(out_prefix, "moments_electron_vs_t")
            mom_ntrl_io = open_ascii_output_file(out_prefix, "moments_neutral_vs_t")
            fields_io = open_ascii_output_file(out_prefix, "fields_vs_t")
            ascii = ascii_ios(ff_io, mom_ion_io, mom_eon_io, mom_ntrl_io, fields_io)
        else
            ascii = ascii_ios(nothing, nothing, nothing, nothing, nothing)
        end

        io_moments = setup_moments_io(out_prefix, io_input.binary_format, r, z,
                                      composition, collisions, evolve_density,
                                      evolve_upar, evolve_ppar, input_dict,
                                      io_input.parallel_io, comm_inter_block[])
        io_dfns = setup_dfns_io(out_prefix, io_input.binary_format,
                                boundary_distributions, r, z, vperp, vpa, vzeta, vr, vz,
                                composition, collisions, evolve_density, evolve_upar,
                                evolve_ppar, input_dict, io_input.parallel_io,
                                comm_inter_block[])

        return ascii, io_moments, io_dfns
    end
    # For other processes in the block, return (nothing, nothing, nothing)
    return nothing, nothing, nothing
end

"""
Get a (sub-)group from a file or group
"""
function get_group() end

"""
Test if a member of a (sub-)group is a group
"""
function is_group() end

"""
Get names of all subgroups
"""
function get_subgroup_keys() end

"""
Get names of all variables
"""
function get_variable_keys() end

"""
    write_single_value!(file_or_group, name, value; description=nothing)

Write a single variable to a file or group. If a description is passed, add as an
attribute of the variable.
"""
function write_single_value!() end

"""
write some overview information for the simulation to the binary file
"""
function write_overview!(fid, composition, collisions, parallel_io, evolve_density,
                         evolve_upar, evolve_ppar)
    @serial_region begin
        overview = create_io_group(fid, "overview")
        write_single_value!(overview, "nspecies", composition.n_species,
                            parallel_io=parallel_io,
                            description="total number of evolved plasma species")
        write_single_value!(overview, "n_ion_species", composition.n_ion_species,
                            parallel_io=parallel_io,
                            description="number of evolved ion species")
        write_single_value!(overview, "n_neutral_species", composition.n_neutral_species,
                            parallel_io=parallel_io,
                            description="number of evolved neutral species")
        write_single_value!(overview, "T_e", composition.T_e, parallel_io=parallel_io,
                            description="fixed electron temperature")
        write_single_value!(overview, "charge_exchange_frequency",
                            collisions.charge_exchange, parallel_io=parallel_io,
                            description="quantity related to the charge exchange frequency")
        write_single_value!(overview, "ionization_frequency", collisions.ionization,
                            parallel_io=parallel_io,
                            description="quantity related to the ionization frequency")
        write_single_value!(overview, "evolve_density", evolve_density,
                            parallel_io=parallel_io,
                            description="is density evolved separately from the distribution function?")
        write_single_value!(overview, "evolve_upar", evolve_upar,
                            parallel_io=parallel_io,
                            description="is parallel flow evolved separately from the distribution function?")
        write_single_value!(overview, "evolve_ppar", evolve_ppar,
                            parallel_io=parallel_io,
                            description="is parallel pressure evolved separately from the distribution function?")
        write_single_value!(overview, "parallel_io", parallel_io,
                            parallel_io=parallel_io,
                            description="is parallel I/O being used?")
    end
end

"""
Save info from the dict with input settings to the output file

Note: assumes all keys in `input_dict` are strings.
"""
function write_input!(fid, input_dict, parallel_io)
    function write_dict(io, section_dict, parallel_io)
        # Function that can be called recursively to write nested Dicts into sub-groups in
        # the output file
        for (key, value) ∈ section_dict
            if isa(value, Dict)
                subsection_io = create_io_group(io, key)
                write_dict(subsection_io, value, parallel_io)
            else
                write_single_value!(io, key, value, parallel_io=parallel_io)
            end
        end
    end
    @serial_region begin
        input_io = create_io_group(fid, "input")
        write_dict(input_io, input_dict, parallel_io)
    end
end

"""
Write the distributions that may be used for boundary conditions to the output file
"""
function write_boundary_distributions!(fid, boundary_distributions, parallel_io,
                                       composition, z, vperp, vpa, vzeta, vr, vz)
    @serial_region begin
        boundary_distributions_io = create_io_group(fid, "boundary_distributions")

        write_single_value!(boundary_distributions_io, "pdf_rboundary_ion_left",
            boundary_distributions.pdf_rboundary_ion[:,:,:,1,:], vpa, vperp, z,
            parallel_io=parallel_io, n_ion_species=composition.n_ion_species,
            description="Initial ion-particle pdf at left radial boundary")
        write_single_value!(boundary_distributions_io, "pdf_rboundary_ion_right",
            boundary_distributions.pdf_rboundary_ion[:,:,:,2,:], vpa, vperp, z,
            parallel_io=parallel_io, n_ion_species=composition.n_ion_species,
            description="Initial ion-particle pdf at right radial boundary")
        write_single_value!(boundary_distributions_io, "pdf_rboundary_neutral_left",
            boundary_distributions.pdf_rboundary_neutral[:,:,:,:,1,:], vz, vr, vzeta, z,
            parallel_io=parallel_io, n_neutral_species=composition.n_neutral_species,
            description="Initial neutral-particle pdf at left radial boundary")
        write_single_value!(boundary_distributions_io, "pdf_rboundary_neutral_right",
            boundary_distributions.pdf_rboundary_neutral[:,:,:,:,2,:], vz, vr, vzeta, z,
            parallel_io=parallel_io, n_neutral_species=composition.n_neutral_species,
            description="Initial neutral-particle pdf at right radial boundary")
    end
    return nothing
end

"""
Define coords group for coordinate information in the output file and write information
about spatial coordinate grids
"""
function define_spatial_coordinates!(fid, z, r, parallel_io)
    @serial_region begin
        # create the "coords" group that will contain coordinate information
        coords = create_io_group(fid, "coords")
        # create the "z" sub-group of "coords" that will contain z coordinate info,
        # including total number of grid points and grid point locations
        define_io_coordinate!(coords, z, "z", "spatial coordinate z", parallel_io)
        # create the "r" sub-group of "coords" that will contain r coordinate info,
        # including total number of grid points and grid point locations
        define_io_coordinate!(coords, r, "r", "spatial coordinate r", parallel_io)

        if parallel_io
            # Parallel I/O produces a single file, so effectively a 'single block'

            # Write variable recording the index of the block within the global domain
            # decomposition
            write_single_value!(coords, "iblock", 0, parallel_io=parallel_io,
                                description="index of this zr block")

            # Write variable recording the total number of blocks in the global domain
            # decomposition
            write_single_value!(coords, "nblocks", 1, parallel_io=parallel_io,
                                description="number of zr blocks")
        else
            # Write a separate file for each block

            # Write variable recording the index of the block within the global domain
            # decomposition
            write_single_value!(coords, "iblock", iblock_index[], parallel_io=parallel_io,
                                description="index of this zr block")

            # Write variable recording the total number of blocks in the global domain
            # decomposition
            write_single_value!(coords, "nblocks", global_size[]÷block_size[],
                                parallel_io=parallel_io, description="number of zr blocks")
        end

        return coords
    end

    # For processes other than the root process of each shared-memory group...
    return nothing
end

"""
Add to coords group in output file information about vspace coordinate grids
"""
function add_vspace_coordinates!(coords, vz, vr, vzeta, vpa, vperp, parallel_io)
    @serial_region begin
        # create the "vz" sub-group of "coords" that will contain vz coordinate info,
        # including total number of grid points and grid point locations
        define_io_coordinate!(coords, vz, "vz", "velocity coordinate v_z", parallel_io)
        # create the "vr" sub-group of "coords" that will contain vr coordinate info,
        # including total number of grid points and grid point locations
        define_io_coordinate!(coords, vr, "vr", "velocity coordinate v_r", parallel_io)
        # create the "vzeta" sub-group of "coords" that will contain vzeta coordinate info,
        # including total number of grid points and grid point locations
        define_io_coordinate!(coords, vzeta, "vzeta", "velocity coordinate v_zeta",
                              parallel_io)
        # create the "vpa" sub-group of "coords" that will contain vpa coordinate info,
        # including total number of grid points and grid point locations
        define_io_coordinate!(coords, vpa, "vpa", "velocity coordinate v_parallel",
                              parallel_io)
        # create the "vperp" sub-group of "coords" that will contain vperp coordinate info,
        # including total number of grid points and grid point locations
        define_io_coordinate!(coords, vperp, "vperp", "velocity coordinate v_perp",
                              parallel_io)
    end

    return nothing
end

"""
define a sub-group for each code coordinate and write to output file
"""
function define_io_coordinate!(parent, coord, coord_name, description, parallel_io)
    @serial_region begin
        # create the "group" sub-group of "parent" that will contain coord_str coordinate info
        group = create_io_group(parent, coord_name, description=description)

        if parallel_io
            # When using parallel I/O, write n_global as n_local because the file is as if
            # it had been produced by a serial run.
            # This is a bit of a hack and should probably be removed when
            # post_processing.jl is updated to be compatible with that.
            write_single_value!(group, "n_local", coord.n_global; parallel_io=parallel_io,
                                description="number of local $coord_name grid points")
        else
            # write the number of local grid points for this coordinate to variable
            # "n_local" within "coords/coord_name" group
            write_single_value!(group, "n_local", coord.n; parallel_io=parallel_io,
                                description="number of local $coord_name grid points")
        end

        # write the number of points within each element for this coordinate to variable
        # "ngrid" within "coords/coord_name" group
        write_single_value!(group, "ngrid", coord.ngrid; parallel_io=parallel_io,
                            description="number of points in each element in $coord_name")

        # write the number of global grid points for this coordinate to variable "n_local"
        # within "coords/coord_name" group
        write_single_value!(group, "n_global", coord.n_global; parallel_io=parallel_io,
                            description="total number of $coord_name grid points")

        if parallel_io
            # write the rank as if whole file was written by rank-0
            write_single_value!(group, "irank", 0, parallel_io=parallel_io,
                                description="rank of this block in the $(coord.name) grid communicator")
        else
            # write the rank in the coord-direction of this process
            write_single_value!(group, "irank", coord.irank, parallel_io=parallel_io,
                                description="rank of this block in the $(coord.name) grid communicator")
        end

        # write the global length of this coordinate to variable "L"
        # within "coords/coord_name" group
        write_single_value!(group, "L", coord.L; parallel_io=parallel_io,
                            description="box length in $coord_name")

        # write the locations of this coordinate's grid points to variable "grid" within "coords/coord_name" group
        write_single_value!(group, "grid", coord.grid, coord; parallel_io=parallel_io,
                            description="$coord_name values sampled by the $coord_name grid")

        # write the integration weights attached to each coordinate grid point
        write_single_value!(group, "wgts", coord.wgts, coord; parallel_io=parallel_io,
                            description="integration weights associated with the $coord_name grid points")

        # write the discretization option for the coordinate
        write_single_value!(group, "discretization", coord.discretization;
                            parallel_io=parallel_io,
                            description="discretization used for $coord_name")

        # write the finite-difference option for the coordinate
        write_single_value!(group, "fd_option", coord.fd_option; parallel_io=parallel_io,
                            description="type of finite difference for $coord_name, if used")

        # write the boundary condition for the coordinate
        write_single_value!(group, "bc", coord.bc; parallel_io=parallel_io,
                            description="boundary condition for $coord_name")

        return group
    end

    # For processes other than the root process of each shared-memory group...
    return nothing
end

"""
    create_dynamic_variable!(file_or_group, name, type, coords::coordinate...;
                             nspecies=1, description=nothing, units=nothing)

Create a time-evolving variable in `file_or_group` named `name` of type `type`. `coords`
are the coordinates corresponding to the dimensions of the array, in the order of the
array dimensions. The species dimension does not have a `coordinate`, so the number of
species is passed as `nspecies`. A description and/or units can be added with the keyword
arguments.
"""
function create_dynamic_variable!() end

"""
define dynamic (time-evolving) moment variables for writing to the hdf5 file
"""
function define_dynamic_moment_variables!(fid, n_ion_species, n_neutral_species,
                                          r::coordinate, z::coordinate, parallel_io)
    @serial_region begin
        dynamic = create_io_group(fid, "dynamic_data", description="time evolving variables")

        io_time = create_dynamic_variable!(dynamic, "time", mk_float; parallel_io=parallel_io,
                                           description="simulation time")

        # io_phi is the handle referring to the electrostatic potential phi
        io_phi = create_dynamic_variable!(dynamic, "phi", mk_float, z, r;
                                          parallel_io=parallel_io,
                                          description="electrostatic potential",
                                          units="T_ref/e")
        # io_Er is the handle for the radial component of the electric field
        io_Er = create_dynamic_variable!(dynamic, "Er", mk_float, z, r;
                                         parallel_io=parallel_io,
                                         description="radial electric field",
                                         units="T_ref/e L_ref")
        # io_Ez is the handle for the zed component of the electric field
        io_Ez = create_dynamic_variable!(dynamic, "Ez", mk_float, z, r;
                                         parallel_io=parallel_io,
                                         description="vertical electric field",
                                         units="T_ref/e L_ref")

        # io_density is the handle for the ion particle density
        io_density = create_dynamic_variable!(dynamic, "density", mk_float, z, r;
                                              n_ion_species=n_ion_species,
                                              parallel_io=parallel_io,
                                              description="ion species density",
                                              units="n_ref")

        # io_upar is the handle for the ion parallel flow density
        io_upar = create_dynamic_variable!(dynamic, "parallel_flow", mk_float, z, r;
                                           n_ion_species=n_ion_species,
                                           parallel_io=parallel_io,
                                           description="ion species parallel flow",
                                           units="c_ref = sqrt(2*T_ref/mi)")

        # io_ppar is the handle for the ion parallel pressure
        io_ppar = create_dynamic_variable!(dynamic, "parallel_pressure", mk_float, z, r;
                                           n_ion_species=n_ion_species,
                                           parallel_io=parallel_io,
                                           description="ion species parallel pressure",
                                           units="n_ref*T_ref")

        # io_qpar is the handle for the ion parallel heat flux
        io_qpar = create_dynamic_variable!(dynamic, "parallel_heat_flux", mk_float, z, r;
                                           n_ion_species=n_ion_species,
                                           parallel_io=parallel_io,
                                           description="ion species parallel heat flux",
                                           units="n_ref*T_ref*c_ref")

        # io_vth is the handle for the ion thermal speed
        io_vth = create_dynamic_variable!(dynamic, "thermal_speed", mk_float, z, r;
                                          n_ion_species=n_ion_species,
                                          parallel_io=parallel_io,
                                          description="ion species thermal speed",
                                          units="c_ref")

        # io_density is the handle for the ion particle density
        io_electron_density = create_dynamic_variable!(dynamic, "electron_density", mk_float, z, r;
                                              parallel_io=parallel_io,
                                              description="electron species density",
                                              units="n_ref")

        # io_electron_upar is the handle for the electron parallel flow density
        io_electron_upar = create_dynamic_variable!(dynamic, "electron_parallel_flow", mk_float, z, r;
                                           parallel_io=parallel_io,
                                           description="electron species parallel flow",
                                           units="c_ref = sqrt(2*T_ref/mi)")

        # io_electron_ppar is the handle for the electron parallel pressure
        io_electron_ppar = create_dynamic_variable!(dynamic, "electron_parallel_pressure", mk_float, z, r;
                                           parallel_io=parallel_io,
                                           description="electron species parallel pressure",
                                           units="n_ref*T_ref")

        # io_electron_qpar is the handle for the electron parallel heat flux
        io_electron_qpar = create_dynamic_variable!(dynamic, "electron_parallel_heat_flux", mk_float, z, r;
                                           parallel_io=parallel_io,
                                           description="electron species parallel heat flux",
                                           units="n_ref*T_ref*c_ref")

        # io_electron_vth is the handle for the electron thermal speed
        io_electron_vth = create_dynamic_variable!(dynamic, "electron_thermal_speed", mk_float, z, r;
                                          parallel_io=parallel_io,
                                          description="electron species thermal speed",
                                          units="c_ref")

        # io_density_neutral is the handle for the neutral particle density
        io_density_neutral = create_dynamic_variable!(dynamic, "density_neutral", mk_float, z, r;
                                                      n_neutral_species=n_neutral_species,
                                                      parallel_io=parallel_io,
                                                      description="neutral species density",
                                                      units="n_ref")

        # io_uz_neutral is the handle for the neutral z momentum density
        io_uz_neutral = create_dynamic_variable!(dynamic, "uz_neutral", mk_float, z, r;
                                                 n_neutral_species=n_neutral_species,
                                                 parallel_io=parallel_io,
                                                 description="neutral species mean z velocity",
                                                 units="c_ref = sqrt(2*T_ref/mi)")

        # io_pz_neutral is the handle for the neutral species zz pressure
        io_pz_neutral = create_dynamic_variable!(dynamic, "pz_neutral", mk_float, z, r;
                                                 n_neutral_species=n_neutral_species,
                                                 parallel_io=parallel_io,
                                                 description="neutral species mean zz pressure",
                                                 units="n_ref*T_ref")

        # io_qz_neutral is the handle for the neutral z heat flux
        io_qz_neutral = create_dynamic_variable!(dynamic, "qz_neutral", mk_float, z, r;
                                                 n_neutral_species=n_neutral_species,
                                                 parallel_io=parallel_io,
                                                 description="neutral species z heat flux",
                                                 units="n_ref*T_ref*c_ref")

        # io_thermal_speed_neutral is the handle for the neutral thermal speed
        io_thermal_speed_neutral = create_dynamic_variable!(
            dynamic, "thermal_speed_neutral", mk_float, z, r;
            n_neutral_species=n_neutral_species,
            parallel_io=parallel_io, description="neutral species thermal speed",
            units="c_ref")

        return io_moments_info(fid, io_time, io_phi, io_Er, io_Ez, 
                               io_density, io_upar, io_ppar, io_qpar, io_vth, 
                               io_electron_density, io_electron_upar, io_electron_ppar, io_electron_qpar, io_electron_vth,
                               io_density_neutral, io_uz_neutral, io_pz_neutral, io_qz_neutral, io_thermal_speed_neutral,
                               parallel_io)
    end

    # For processes other than the root process of each shared-memory group...
    return nothing
end

"""
define dynamic (time-evolving) distribution function variables for writing to the output
file
"""
function define_dynamic_dfn_variables!(fid, r, z, vperp, vpa, vzeta, vr, vz,
                                       n_ion_species, n_neutral_species, parallel_io)

    @serial_region begin
        io_moments = define_dynamic_moment_variables!(fid, n_ion_species,
                                                      n_neutral_species, r, z,
                                                      parallel_io)

        dynamic = get_group(fid, "dynamic_data")

        # io_f is the handle for the ion pdf
        io_f = create_dynamic_variable!(dynamic, "f", mk_float, vpa, vperp, z, r;
                                        n_ion_species=n_ion_species,
                                        parallel_io=parallel_io,
                                        description="ion species distribution function")

        # io_f_neutral is the handle for the neutral pdf
        io_f_neutral = create_dynamic_variable!(dynamic, "f_neutral", mk_float, vz, vr, vzeta, z, r;
                                                n_neutral_species=n_neutral_species,
                                                parallel_io=parallel_io,
                                                description="neutral species distribution function")

        return io_dfns_info(fid, io_f, io_f_neutral, parallel_io, io_moments)
    end

    # For processes other than the root process of each shared-memory group...
    return nothing
end

"""
Add an attribute to a file, group or variable
"""
function add_attribute!() end

"""
Open an output file, selecting the backend based on io_option
"""
function open_output_file(prefix, binary_format, parallel_io, io_comm)
    if binary_format == hdf5
        return open_output_file_hdf5(prefix, parallel_io, io_comm)
    elseif binary_format == netcdf
        return open_output_file_netcdf(prefix, parallel_io, io_comm)
    else
        error("Unsupported I/O format $binary_format")
    end
end

"""
setup file i/o for moment variables
"""
function setup_moments_io(prefix, binary_format, r, z, composition, collisions,
                          evolve_density, evolve_upar, evolve_ppar, input_dict,
                          parallel_io, io_comm)
    @serial_region begin
        moments_prefix = string(prefix, ".moments")
        if !parallel_io
            moments_prefix *= ".$(iblock_index[])"
        end
        fid = open_output_file(moments_prefix, binary_format, parallel_io, io_comm)

        # write a header to the output file
        add_attribute!(fid, "file_info", "Output moments data from the moment_kinetics code")

        # write some overview information to the output file
        write_overview!(fid, composition, collisions, parallel_io, evolve_density,
                        evolve_upar, evolve_ppar)

        # write the input settings
        write_input!(fid, input_dict, parallel_io)

        ### define coordinate dimensions ###
        define_spatial_coordinates!(fid, z, r, parallel_io)

        ### create variables for time-dependent quantities and store them ###
        ### in a struct for later access ###
        io_moments = define_dynamic_moment_variables!(
            fid, composition.n_ion_species, composition.n_neutral_species, r, z, parallel_io)

        return io_moments
    end

    # For processes other than the root process of each shared-memory group...
    return nothing
end

"""
setup file i/o for distribution function variables
"""
function setup_dfns_io(prefix, binary_format, boundary_distributions, r, z, vperp, vpa,
                       vzeta, vr, vz, composition, collisions, evolve_density,
                       evolve_upar, evolve_ppar, input_dict, parallel_io, io_comm)

    @serial_region begin
        dfns_prefix = string(prefix, ".dfns")
        if !parallel_io
            dfns_prefix *= ".$(iblock_index[])"
        end
        fid = open_output_file(dfns_prefix, binary_format, parallel_io, io_comm)

        # write a header to the output file
        add_attribute!(fid, "file_info",
                       "Output distribution function data from the moment_kinetics code")

        # write some overview information to the output file
        write_overview!(fid, composition, collisions, parallel_io, evolve_density,
                        evolve_upar, evolve_ppar)

        # write the input settings
        write_input!(fid, input_dict, parallel_io)

        # write the distributions that may be used for boundary conditions to the output
        # file
        write_boundary_distributions!(fid, boundary_distributions, parallel_io,
                                      composition, z, vperp, vpa, vzeta, vr, vz)

        ### define coordinate dimensions ###
        coords_group = define_spatial_coordinates!(fid, z, r, parallel_io)
        add_vspace_coordinates!(coords_group, vz, vr, vzeta, vpa, vperp, parallel_io)

        ### create variables for time-dependent quantities and store them ###
        ### in a struct for later access ###
        io_dfns = define_dynamic_dfn_variables!(
            fid, r, z, vperp, vpa, vzeta, vr, vz, composition.n_ion_species,
            composition.n_neutral_species, parallel_io)

        return io_dfns
    end

    # For processes other than the root process of each shared-memory group...
    return nothing
end

"""
    append_to_dynamic_var(io_var, data, t_idx, coords...)

Append `data` to the dynamic variable `io_var`. The time-index of the data being appended
is `t_idx`. `coords...` is used to get the ranges to write from/to (needed for parallel
I/O) - the entries in the `coords` tuple can be either `coordinate` instances or integers
(for an integer `n` the range is `1:n`).
"""
function append_to_dynamic_var() end

"""
write time-dependent moments data to the binary output file
"""
function write_moments_data_to_binary(moments, fields, t, n_ion_species,
                                      n_neutral_species, io_moments, t_idx, r, z)
    @serial_region begin
        # Only read/write from first process in each 'block'

        # add the time for this time slice to the hdf5 file
        append_to_dynamic_var(io_moments.time, t, t_idx)

        # add the electrostatic potential and electric field components at this time slice to the hdf5 file
        append_to_dynamic_var(io_moments.phi, fields.phi, t_idx, z, r)
        append_to_dynamic_var(io_moments.Er, fields.Er, t_idx, z, r)
        append_to_dynamic_var(io_moments.Ez, fields.Ez, t_idx, z, r)

        # add the density data at this time slice to the output file
        append_to_dynamic_var(io_moments.density, moments.ion.dens, t_idx, z, r,
                              n_ion_species)
        append_to_dynamic_var(io_moments.parallel_flow, moments.ion.upar, t_idx, z, r,
                              n_ion_species)
        append_to_dynamic_var(io_moments.parallel_pressure, moments.ion.ppar, t_idx,
                              z, r, n_ion_species)
        append_to_dynamic_var(io_moments.parallel_heat_flux, moments.ion.qpar, t_idx,
                              z, r, n_ion_species)
        append_to_dynamic_var(io_moments.thermal_speed, moments.ion.vth, t_idx, z, r,
                              n_ion_species)
        # add the electron velocity-moments data at this time slice to the output file
        append_to_dynamic_var(io_moments.electron_density, moments.electron.dens, t_idx, z, r)
        append_to_dynamic_var(io_moments.electron_parallel_flow, moments.electron.upar, t_idx, z, r)
        append_to_dynamic_var(io_moments.electron_parallel_pressure, moments.electron.ppar, t_idx, z, r)
        append_to_dynamic_var(io_moments.electron_parallel_heat_flux, moments.electron.qpar, t_idx, z, r)
        append_to_dynamic_var(io_moments.electron_thermal_speed, moments.electron.vth, t_idx, z, r)
        # add the neutral velocity-moments data at this time slice to the output file
        if n_neutral_species > 0
            append_to_dynamic_var(io_moments.density_neutral, moments.neutral.dens, t_idx,
                                  z, r, n_neutral_species)
            append_to_dynamic_var(io_moments.uz_neutral, moments.neutral.uz, t_idx, z, r,
                                  n_neutral_species)
            append_to_dynamic_var(io_moments.pz_neutral, moments.neutral.pz, t_idx, z, r,
                                  n_neutral_species)
            append_to_dynamic_var(io_moments.qz_neutral, moments.neutral.qz, t_idx, z, r,
                                  n_neutral_species)
            append_to_dynamic_var(io_moments.thermal_speed_neutral, moments.neutral.vth,
                                  t_idx, z, r, n_neutral_species)
        end
    end
    return nothing
end

"""
write time-dependent distribution function data to the binary output file
"""
function write_dfns_data_to_binary(ff, ff_neutral, moments, fields, t, n_ion_species,
                                   n_neutral_species, io_dfns, t_idx, r, z, vperp, vpa,
                                   vzeta, vr, vz)
    @serial_region begin
        # Only read/write from first process in each 'block'

        # Write the moments for this time slice to the output file.
        # This also updates the time.
        write_moments_data_to_binary(moments, fields, t, n_ion_species, n_neutral_species,
                                     io_dfns.io_moments, t_idx, r, z)

        # add the distribution function data at this time slice to the output file
        append_to_dynamic_var(io_dfns.f, ff, t_idx, vpa, vperp, z, r, n_ion_species)
        if n_neutral_species > 0
            append_to_dynamic_var(io_dfns.f_neutral, ff_neutral, t_idx, vz, vr, vzeta, z,
                                  r, n_neutral_species)
        end
    end
    return nothing
end

@debug_shared_array begin
    # Special versions when using DebugMPISharedArray to avoid implicit conversion to
    # Array, which is forbidden.
    function write_moments_data_to_binary(moments, fields, t, n_ion_species,
            n_neutral_species, io_moments, t_idx, r, z)
        @serial_region begin
            # Only read/write from first process in each 'block'

            # add the time for this time slice to the hdf5 file
            append_to_dynamic_var(io_moments.time, t, t_idx)

            # add the electrostatic potential and electric field components at this time slice to the hdf5 file
            append_to_dynamic_var(io_moments.phi, fields.phi.data, t_idx, z, r)
            append_to_dynamic_var(io_moments.Er, fields.Er.data, t_idx, z, r)
            append_to_dynamic_var(io_moments.Ez, fields.Ez.data, t_idx, z, r)

            # add the density data at this time slice to the output file
            append_to_dynamic_var(io_moments.density, moments.ion.dens.data, t_idx, z,
                                  r, n_ion_species)
            append_to_dynamic_var(io_moments.parallel_flow, moments.ion.upar.data,
                                  t_idx, z, r, n_ion_species)
            append_to_dynamic_var(io_moments.parallel_pressure, moments.ion.ppar.data,
                                  t_idx, z, r, n_ion_species)
            append_to_dynamic_var(io_moments.parallel_heat_flux,
                                  moments.ion.qpar.data, t_idx, z, r, n_ion_species)
            append_to_dynamic_var(io_moments.thermal_speed, moments.ion.vth.data,
                                  t_idx, z, r, n_ion_species)
            # add the electron velocity-moments data at this time slice to the output file
            append_to_dynamic_var(io_moments.electron_density, moments.electron.dens.data, t_idx, z, r)
            append_to_dynamic_var(io_moments.electron_parallel_flow, moments.electron.upar.data, t_idx, z, r)
            append_to_dynamic_var(io_moments.electron_parallel_pressure, moments.electron.ppar.data, t_idx, z, r)
            append_to_dynamic_var(io_moments.electron_parallel_heat_flux, moments.electron.qpar.data, t_idx, z, r)
            append_to_dynamic_var(io_moments.electron_thermal_speed, moments.electron.vth.data, t_idx, z, r)
            if n_neutral_species > 0
                append_to_dynamic_var(io_moments.density_neutral,
                                      moments.neutral.dens.data, t_idx, z, r,
                                      n_neutral_species)
                append_to_dynamic_var(io_moments.uz_neutral, moments.neutral.uz.data,
                                      t_idx, z, r, n_neutral_species)
                append_to_dynamic_var(io_moments.pz_neutral, moments.neutral.pz.data,
                                      t_idx, z, r, n_neutral_species)
                append_to_dynamic_var(io_moments.qz_neutral, moments.neutral.qz.data,
                                      t_idx, z, r, n_neutral_species)
                append_to_dynamic_var(io_moments.thermal_speed_neutral,
                                      moments.neutral.vth.data, t_idx, z, r,
                                      n_neutral_species)
            end
        end
        return nothing
    end
end

@debug_shared_array begin
    # Special versions when using DebugMPISharedArray to avoid implicit conversion to
    # Array, which is forbidden.
    function write_dfns_data_to_binary(ff::DebugMPISharedArray,
            ff_neutral::DebugMPISharedArray, moments, t, n_ion_species, n_neutral_species,
            io_dfns, t_idx, r, z, vperp, vpa, vzeta, vr, vz)
        @serial_region begin
            # Only read/write from first process in each 'block'

            # Write the moments for this time slice to the output file
            # This also updates the time.
            write_moments_data_to_binary(moments, fields, t, n_ion_species, n_neutral_species,
                                         io_dfns.io_moments, t_idx, r, z)

            # add the distribution function data at this time slice to the output file
            append_to_dynamic_var(io_dfns.f, ff.data, t_idx, vpa, vperp, z, r, n_ion_species)
            if n_neutral_species > 0
                append_to_dynamic_var(io_dfns.f_neutral, ff_neutral.data, t_idx, vz, vr, vzeta, z,
                                      r, n_neutral_species)
            end
        end
        return nothing
    end
end

"""
close all opened output files
"""
function finish_file_io(ascii_io::Union{ascii_ios,Nothing},
                        binary_moments::Union{io_moments_info,Nothing},
                        binary_dfns::Union{io_dfns_info,Nothing})
    @serial_region begin
        # Only read/write from first process in each 'block'

        if ascii_io !== nothing
            # get the fields in the ascii_ios struct
            ascii_io_fields = fieldnames(typeof(ascii_io))
            for x ∈ ascii_io_fields
                io = getfield(ascii_io, x)
                if io !== nothing
                    close(io)
                end
            end
        end
        if binary_moments !== nothing
            close(binary_moments.fid)
        end
        if binary_dfns !== nothing
            close(binary_dfns.fid)
        end
    end
    return nothing
end

# Include the possible implementations of binary I/O functions
include("file_io_netcdf.jl")
include("file_io_hdf5.jl")

"""
"""
#function write_data_to_ascii(pdf, moments, fields, vpa, vperp, z, r, t, n_ion_species,
function write_data_to_ascii(moments, fields, z, r, t, n_ion_species,
                             n_neutral_species, ascii_io::Union{ascii_ios,Nothing})
    if ascii_io === nothing || ascii_io.moments_ion === nothing
        # ascii I/O is disabled
        return nothing
    end

    @serial_region begin
        # Only read/write from first process in each 'block'

        #write_f_ascii(pdf, z, vpa, t, ascii_io.ff)
        write_moments_ion_ascii(moments.ion, z, r, t, n_ion_species, ascii_io.moments_ion)
        write_moments_electron_ascii(moments.electron, z, r, t, ascii_io.moments_electron)
        if n_neutral_species > 0
            write_moments_neutral_ascii(moments.neutral, z, r, t, n_neutral_species, ascii_io.moments_neutral)
        end
        write_fields_ascii(fields, z, r, t, ascii_io.fields)
    end
    return nothing
end

"""
write the function f(z,vpa) at this time slice
"""
function write_f_ascii(f, z, vpa, t, ascii_io)
    @serial_region begin
        # Only read/write from first process in each 'block'

        @inbounds begin
            #n_species = size(f,3)
            #for is ∈ 1:n_species
                for j ∈ 1:vpa.n
                    for i ∈ 1:z.n
                        println(ascii_io,"t: ", t, "   z: ", z.grid[i],
                            "  vpa: ", vpa.grid[j], "   fion: ", f.ion.norm[i,j,1], 
                            "   fneutral: ", f.neutral.norm[i,j,1])
                    end
                    println(ascii_io)
                end
                println(ascii_io)
            #end
            #println(ascii_io)
        end
    end
    return nothing
end

"""
write moments of the ion species distribution function f at this time slice
"""
function write_moments_ion_ascii(mom, z, r, t, n_species, ascii_io)
    @serial_region begin
        # Only read/write from first process in each 'block'

        @inbounds begin
            for is ∈ 1:n_species
                for ir ∈ 1:r.n
                    for iz ∈ 1:z.n
                        println(ascii_io,"t: ", t, "   species: ", is, "   r: ", r.grid[ir], "   z: ", z.grid[iz],
                            "  dens: ", mom.dens[iz,ir,is], "   upar: ", mom.upar[iz,ir,is],
                            "   ppar: ", mom.ppar[iz,ir,is], "   qpar: ", mom.qpar[iz,ir,is])
                    end
                end
            end
        end
        println(ascii_io,"")
    end
    return nothing
end

"""
write moments of the ion species distribution function f at this time slice
"""
function write_moments_electron_ascii(mom, z, r, t, ascii_io)
    @serial_region begin
        # Only read/write from first process in each 'block'
    
        @inbounds begin
            for ir ∈ 1:r.n
                for iz ∈ 1:z.n
                    println(ascii_io,"t: ", t, "   r: ", r.grid[ir], "   z: ", z.grid[iz],
                            "  dens: ", mom.dens[iz,ir], "   upar: ", mom.upar[iz,ir],
                            "   ppar: ", mom.ppar[iz,ir], "   qpar: ", mom.qpar[iz,ir])
                end
            end
        end
        println(ascii_io,"")
    end
    return nothing
end

"""
write moments of the neutral species distribution function f_neutral at this time slice
"""
function write_moments_neutral_ascii(mom, z, r, t, n_species, ascii_io)
    @serial_region begin
        # Only read/write from first process in each 'block'

        @inbounds begin
            for is ∈ 1:n_species
                for ir ∈ 1:r.n
                    for iz ∈ 1:z.n
                        println(ascii_io,"t: ", t, "   species: ", is, "   r: ", r.grid[ir], "   z: ", z.grid[iz],
                            "  dens: ", mom.dens[iz,ir,is], "   uz: ", mom.uz[iz,ir,is],
                            "   ur: ", mom.ur[iz,ir,is], "   uzeta: ", mom.uzeta[iz,ir,is],
                            "   pz: ", mom.pz[iz,ir,is])
                    end
                end
            end
        end
        println(ascii_io,"")
    end
    return nothing
end

"""
write electrostatic potential at this time slice
"""
function write_fields_ascii(flds, z, r, t, ascii_io)
    @serial_region begin
        # Only read/write from first process in each 'block'

        @inbounds begin
            for ir ∈ 1:r.n
                for iz ∈ 1:z.n
                    println(ascii_io,"t: ", t, "   r: ", r.grid[ir],"   z: ", z.grid[iz], "  phi: ", flds.phi[iz,ir],
                            " Ez: ", flds.Ez[iz,ir])
                end
            end
        end
        println(ascii_io,"")
    end
    return nothing
end

"""
accepts an option name which has been identified as problematic and returns
an appropriate error message
"""
function input_option_error(option_name, input)
    msg = string("'",input,"'")
    msg = string(msg, " is not a valid ", option_name)
    error(msg)
    return nothing
end

"""
opens an output file with the requested prefix and extension
and returns the corresponding io stream (identifier)
"""
function open_ascii_output_file(prefix, ext)
    str = string(prefix,".",ext)
    return io = open(str,"w")
end

"""
An nc_info instance that may be initialised for writing debug output

This is a non-const module variable, so does cause type instability, but it is only used
for debugging (from `debug_dump()`) so performance is not critical.
"""
debug_output_file = nothing

"""
Global counter for calls to debug_dump
"""
const debug_output_counter = Ref(1)

"""
    debug_dump(ff, dens, upar, ppar, phi, t; istage=0, label="")
    debug_dump(fvec::scratch_pdf, fields::em_fields_struct, t; istage=0, label="")

Dump variables into a NetCDF file for debugging

Intended to be called more frequently than `write_data_to_binary()`, possibly several
times within a timestep, so includes a `label` argument to identify the call site.

Writes to a file called `debug_output.h5` in the current directory.

Can either be called directly with the arrays to be dumped (fist signature), or using
`scratch_pdf` and `em_fields_struct` structs.

`nothing` can be passed to any of the positional arguments (if they are unavailable at a
certain point in the code, or just not interesting). `t=nothing` will set `t` to the
value saved in the previous call (or 0.0 on the first call). Passing `nothing` to the
other arguments will set that array to `0.0` for this call (need to write some value so
all the arrays have the same length, with an entry for each call to `debug_dump()`).
"""
function debug_dump end
function debug_dump(vz::coordinate, vr::coordinate, vzeta::coordinate, vpa::coordinate,
                    vperp::coordinate, z::coordinate, r::coordinate, t::mk_float;
                    ff=nothing, dens=nothing, upar=nothing, ppar=nothing, qpar=nothing,
                    vth=nothing,
                    ff_neutral=nothing, dens_neutral=nothing, uz_neutral=nothing,
                    #ur_neutral=nothing, uzeta_neutral=nothing,
                    pz_neutral=nothing,
                    #pr_neutral=nothing, pzeta_neutral=nothing,
                    qz_neutral=nothing,
                    #qr_neutral=nothing, qzeta_neutral=nothing,
                    vth_neutral=nothing,
                    phi=nothing, Er=nothing, Ez=nothing,
                    istage=0, label="")
    global debug_output_file

    # Only read/write from first process in each 'block'
    _block_synchronize()
    @serial_region begin
        if debug_output_file === nothing
            # Open the file the first time`debug_dump()` is called

            debug_output_counter[] = 1

            (nvpa, nvperp, nz, nr, n_species) = size(ff)
            prefix = "debug_output.$(iblock_index[])"
            filename = string(prefix, ".h5")
            # if a file with the requested name already exists, remove it
            isfile(filename) && rm(filename)
            # create the new NetCDF file
            fid = open_output_file_hdf5(prefix)
            # write a header to the NetCDF file
            add_attribute!(fid, "file_info",
                           "This is a file containing debug output from the moment_kinetics code")

            ### define coordinate dimensions ###
            coords_group = define_spatial_coordinates!(fid, z, r, false)
            add_vspace_coordinates!(coords_group, vz, vr, vzeta, vpa, vperp, false)

            ### create variables for time-dependent quantities and store them ###
            ### in a struct for later access ###
            io_moments = define_dynamic_moment_variables!(fid, composition.n_ion_species,
                                                          composition.n_neutral_species,
                                                          r, z, false)
            io_dfns = define_dynamic_dfn_variables!(
                fid, r, z, vperp, vpa, vzeta, vr, vz, composition.n_ion_species,
                composition.n_neutral_species, false)

            # create the "istage" variable, used to identify the rk stage where
            # `debug_dump()` was called
            dynamic = fid["dynamic_data"]
            io_istage = create_dynamic_variable!(dynamic, "istage", mk_int;
                                                 parallel_io=parallel_io,
                                                 description="rk istage")
            # create the "label" variable, used to identify the `debug_dump()` call-site
            io_label = create_dynamic_variable!(dynamic, "label", String;
                                                parallel_io=parallel_io,
                                                description="call-site label")

            # create a struct that stores the variables and other info needed for
            # writing to the netcdf file during run-time
            debug_output_file = (fid=fid, moments=io_moments, dfns=io_dfns,
                                 istage=io_istage, label=io_label)
        end

        # add the time for this time slice to the netcdf file
        if t === nothing
            if debug_output_counter[] == 1
                debug_output_file.moments.time[debug_output_counter[]] = 0.0
            else
                debug_output_file.moments.time[debug_output_counter[]] =
                debug_output_file.moments.time[debug_output_counter[]-1]
            end
        else
            debug_output_file.moments.time[debug_output_counter[]] = t
        end
        # add the rk istage for this call to the netcdf file
        debug_output_file.istage[debug_output_counter[]] = istage
        # add the label for this call to the netcdf file
        debug_output_file.label[debug_output_counter[]] = label
        # add the distribution function data at this time slice to the netcdf file
        if ff === nothing
            debug_output_file.dfns.ion_f[:,:,:,:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.dfns.ion_f[:,:,:,:,:,debug_output_counter[]] = ff
        end
        # add the moments data at this time slice to the netcdf file
        if dens === nothing
            debug_output_file.moments.density[:,:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.moments.density[:,:,:,debug_output_counter[]] = dens
        end
        if upar === nothing
            debug_output_file.moments.parallel_flow[:,:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.moments.parallel_flow[:,:,:,debug_output_counter[]] = upar
        end
        if ppar === nothing
            debug_output_file.moments.parallel_pressure[:,:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.moments.parallel_pressure[:,:,:,debug_output_counter[]] = ppar
        end
        if qpar === nothing
            debug_output_file.moments.parallel_heat_flux[:,:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.moments.parallel_heat_flux[:,:,:,debug_output_counter[]] = qpar
        end
        if vth === nothing
            debug_output_file.moments.thermal_speed[:,:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.moments.thermal_speed[:,:,:,debug_output_counter[]] = vth
        end

        # add the neutral distribution function data at this time slice to the netcdf file
        if ff_neutral === nothing
            debug_output_file.dfns.f_neutral[:,:,:,:,:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.dfns.f_neutral[:,:,:,:,:,:,debug_output_counter[]] = ff_neutral
        end
        # add the neutral moments data at this time slice to the netcdf file
        if dens === nothing
            debug_output_file.moments.density_neutral[:,:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.moments.density_neutral[:,:,:,debug_output_counter[]] = dens_neutral
        end
        if uz_neutral === nothing
            debug_output_file.moments.uz_neutral[:,:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.moments.uz_neutral[:,:,:,debug_output_counter[]] = uz_neutral
        end
        if pz_neutral === nothing
            debug_output_file.moments.pz_neutral[:,:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.moments.pz_neutral[:,:,:,debug_output_counter[]] = pz_neutral
        end
        if qz_neutral === nothing
            debug_output_file.moments.qz_neutral[:,:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.moments.qz_neutral[:,:,:,debug_output_counter[]] = qz_neutral
        end
        if vth_neutral === nothing
            debug_output_file.moments.thermal_speed_neutral[:,:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.moments.thermal_speed_neutral[:,:,:,debug_output_counter[]] = vth_neutral
        end

        # add the electrostatic potential data at this time slice to the netcdf file
        if phi === nothing
            debug_output_file.moments.phi[:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.moments.phi[:,:,debug_output_counter[]] = phi
        end
        if Er === nothing
            debug_output_file.moments.Er[:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.moments.Er[:,:,debug_output_counter[]] = Er
        end
        if Ez === nothing
            debug_output_file.moments.Ez[:,:,debug_output_counter[]] = 0.0
        else
            debug_output_file.moments.Ez[:,:,debug_output_counter[]] = Ez
        end
    end

    debug_output_counter[] += 1

    _block_synchronize()

    return nothing
end
function debug_dump(fvec::Union{scratch_pdf,Nothing},
                    fields::Union{em_fields_struct,Nothing}, vz, vr, vzeta, vpa, vperp, z,
                    r, t; istage=0, label="")
    if fvec === nothing
        pdf = nothing
        density = nothing
        upar = nothing
        ppar = nothing
        pdf_neutral = nothing
        density_neutral = nothing
    else
        pdf = fvec.pdf
        density = fvec.density
        upar = fvec.upar
        ppar = fvec.ppar
        pdf_neutral = fvec.pdf_neutral
        density_neutral = fvec.density_neutral
    end
    if fields === nothing
        phi = nothing
        Er = nothing
        Ez = nothing
    else
        phi = fields.phi
        Er = fields.Er
        Ez = fields.Ez
    end
    return debug_dump(vz, vr, vzeta, vpa, vperp, z, r, t; ff=pdf, dens=density, upar=upar,
                      ppar=ppar, ff_neutral=pdf_neutral, dens_neutral=density_neutral,
                      phi=phi, Er=Er, Ez=Ez, t, istage=istage, label=label)
end

end

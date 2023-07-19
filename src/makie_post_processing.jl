"""
Post processing functions using Makie.jl

Options are read by default from a file `post_processing_input.toml`, if it exists.

The plots can be generated from the command line by running
```
julia --project run_makie_post_processing.jl dir1 [dir2 [dir3 ...]]
```
"""
module makie_post_processing

export makie_post_process, generate_example_input_file,
       setup_makie_post_processing_input!, get_run_info, postproc_load_variable,
       positive_or_nan

using ..array_allocation: allocate_float
using ..coordinates: define_coordinate
using ..input_structs: grid_input, advection_input
using ..looping: all_dimensions, ion_dimensions, neutral_dimensions
using ..moment_kinetics_input: mk_input, set_defaults_and_check_top_level!,
                               set_defaults_and_check_section!, Dict_to_NamedTuple
using ..load_data: open_readonly_output_file, get_group, load_block_data,
                   load_coordinate_data, load_distributed_charged_pdf_slice,
                   load_distributed_neutral_pdf_slice, load_input, load_mk_options,
                   load_species_data, load_time_data
using ..post_processing: construct_global_zr_coords, get_geometry_and_composition,
                         read_distributed_zr_data!
using ..type_definitions: mk_float, mk_int

using Combinatorics
using Glob
using LsqFit
using MPI
using NaNMath
using OrderedCollections
using TOML

using CairoMakie

const default_input_file_name = "post_processing_input.toml"

"""
Global dict containing settings for makie_post_processing. Can be re-loaded at any time
to change settings.

Is an OrderedDict so the order of sections is nicer if `input_dict` is written out as a
TOML file.
"""
const input_dict = OrderedDict{String,Any}()

"""
Global dict containing settings for makie_post_processing for files with distribution
function output. Can be re-loaded at any time to change settings.

Is an OrderedDict so the order of sections is nicer if `input_dict_dfns` is written out as
a TOML file.
"""
const input_dict_dfns = OrderedDict{String,Any}()

const em_variables = ("phi", "Er", "Ez")
const ion_moment_variables = ("density", "parallel_flow", "parallel_pressure",
                              "thermal_speed", "temperature", "parallel_heat_flux")
const neutral_moment_variables = ("density_neutral", "uz_neutral", "pz_neutral",
                                  "thermal_speed_neutral", "temperature_neutral",
                                  "qz_neutral")
const all_moment_variables = tuple(em_variables..., ion_moment_variables...,
                                   neutral_moment_variables...)

const ion_dfn_variables = ("f",)
const neutral_dfn_variables = ("f_neutral",)
const all_dfn_variables = tuple(ion_dfn_variables..., neutral_dfn_variables...)

const ion_variables = tuple(ion_moment_variables..., ion_dfn_variables)
const neutral_variables = tuple(neutral_moment_variables..., neutral_dfn_variables)
const all_variables = tuple(all_moment_variables..., all_dfn_variables...)

const one_dimension_combinations_no_t = setdiff(all_dimensions, (:s, :sn))
const one_dimension_combinations = (:t, one_dimension_combinations_no_t...)
const two_dimension_combinations_no_t = Tuple(
          Tuple(c) for c in unique((combinations(setdiff(ion_dimensions, (:s,)), 2)...,
                                    combinations(setdiff(neutral_dimensions, (:sn,)), 2)...)))
const two_dimension_combinations = Tuple(
         Tuple(c) for c in
         unique((combinations((:t, setdiff(ion_dimensions, (:s,))...), 2)...,
                 combinations((:t, setdiff(neutral_dimensions, (:sn,))...), 2)...)))

"""
    makie_post_process(run_dir...;
                       input_file::String=default_input_file_name,
                       restart_index::Union{Nothing,mk_int,Tuple}=nothing)

Run post processing with input read from a TOML file

`run_dir...` is the path to the directory to plot from. If more than one `run_dir` is
given, plots comparing the runs in `run_dir...`.

`restart_index` specifies which restart to read if there are multiple restarts. The
default (`nothing`) reads all restarts and concatenates them. An integer value reads the
restart with that index - `-1` indicates the latest restart (which does not have an
index). A tuple with the same length as `run_dir` can also be passed to give a different
`restart_index` for each run.

If `input_file` does not exist, prints warning and uses default options.
"""
function makie_post_process(run_dir...;
                            input_file::String=default_input_file_name,
                            restart_index::Union{Nothing,mk_int,Tuple}=nothing)
    if isfile(input_file)
        new_input_dict = TOML.parsefile(input_file)
    else
        println("Warning: $input_file does not exist, using default post-processing "
                * "options")
        new_input_dict = OrderedDict{String,Any}()
    end

    return makie_post_process(run_dir, new_input_dict; restart_index=restart_index)
end

"""
    makie_post_process(run_dir::Union{String,Tuple},
                       new_input_dict::Dict{String,Any};
                       restart_index::Union{Nothing,mk_int,Tuple}=nothing)

Run post prossing, with (non-default) input given in a Dict

`run_dir` is the path to an output directory, or (to make comparison plots) a tuple of
paths to output directories.

`input_dict` is a dictionary containing settings for the post-processing.

`restart_index` specifies which restart to read if there are multiple restarts. The
default (`nothing`) reads all restarts and concatenates them. An integer value reads the
restart with that index - `-1` indicates the latest restart (which does not have an
index). A tuple with the same length as `run_dir` can also be passed to give a different
`restart_index` for each run.
"""
function makie_post_process(run_dir::Union{String,Tuple},
                            new_input_dict::AbstractDict{String,Any};
                            restart_index::Union{Nothing,mk_int,Tuple}=nothing)
    if isa(run_dir, String)
        # Make run_dir a one-element tuple if it is not a tuple
        run_dir = (run_dir,)
    end
    # Normalise by removing any trailing slashes - with a slash basename() would return an
    # empty string
    run_dir = Tuple(rstrip(ri, '/') for ri ∈ run_dir)

    new_input_dict = convert_to_OrderedDicts!(new_input_dict)

    if !isa(restart_index, Tuple)
        # Convert scalar restart_index to Tuple so we can treat everything the same below
        restart_index = Tuple(restart_index for _ ∈ run_dir)
    end

    run_label = Tuple(basename(r) for r ∈ run_dir)

    # Special handling for itime_* and itime_*_dfns because they are needed in order to
    # set up `time` and `time_dfns` in run_info, but run_info is needed to set several
    # other default values in setup_makie_post_processing_input!().
    itime_min = get(new_input_dict, "itime_min", 1)
    itime_max = get(new_input_dict, "itime_max", -1)
    itime_skip = get(new_input_dict, "itime_skip", 1)
    itime_min_dfns = get(new_input_dict, "itime_min_dfns", 1)
    itime_max_dfns = get(new_input_dict, "itime_max_dfns", -1)
    itime_skip_dfns = get(new_input_dict, "itime_skip_dfns", 1)
    run_info_moments = Tuple(get_run_info(p, i, itime_min=itime_min, itime_max=itime_max,
                                          itime_skip=itime_skip)
                             for (p,i) in zip(run_dir, restart_index))
    run_info_dfns = Tuple(get_run_info(p, i, itime_min=itime_min_dfns,
                                       itime_max=itime_max_dfns,
                                       itime_skip=itime_skip_dfns, dfns=true)
                          for (p,i) in zip(run_dir, restart_index))

    if all(ri === nothing for ri in (run_info_moments..., run_info_dfns...))
        error("No output files found for either moments or dfns in $run_dir")
    end
    setup_makie_post_processing_input!(new_input_dict, run_info_moments=run_info_moments,
                                       run_info_dfns=run_info_dfns)

    is_1D = all(ri !== nothing && ri.r.n == 1 for ri ∈ run_info_moments)

    # Only plot neutral stuff if all runs have neutrals
    if any(ri !== nothing for ri ∈ run_info_moments)
        has_neutrals = all(r.n_neutral_species > 0 for r in run_info_moments)
    else
        has_neutrals = all(r.n_neutral_species > 0 for r in run_info_dfns)
    end

    is_1V = all(ri !== nothing && ri.vperp.n == 1 && ri.vzeta.n == 1 && ri.vr.n == 1
                for ri ∈ run_info_dfns)

    # Plots from moment variables
    #############################

    moment_variable_list = tuple(em_variables..., ion_moment_variables...)
    if has_neutrals
        moment_variable_list = tuple(moment_variable_list..., neutral_moment_variables...)
    end

    if any(ri !== nothing for ri ∈ run_info_moments)
        # Default to plotting moments from 'moments' files
        run_info = run_info_moments
    else
        # Fall back to trying to plot from 'dfns' files if those are all we have
        run_info = run_info_dfns
    end

    if length(run_info) == 1
        plot_prefix = joinpath(run_dir[1], basename(run_dir[1])) * "_"
    else
        plot_prefix = "comparison_plots/compare_"
    end

    for variable_name ∈ moment_variable_list
        plots_for_variable(run_info, variable_name; plot_prefix=plot_prefix, is_1D=is_1D,
                           is_1V=is_1V)
    end

    # Plots from distribution function variables
    ############################################
    if any(ri !== nothing for ri in run_info_dfns)
        for variable_name ∈ all_dfn_variables
            #plots_for_dfn_variable(run_info_dfns, variable_name; plot_prefix=plot_prefix,
            #                       is_1D=is_1D, is_1V=is_1V)
        end
    end

    return nothing
end

"""
    generate_example_input_file(filename::String=$default_input_file_name;
                                overwrite::Bool=false)

Create an example makie-post-processing input file.

Every option is commented out, but filled with the default value.

Pass `filename` to choose the name of the example file (defaults to the default input file
name used by `makie_post_process()`).

Pass `overwrite=true` to overwrite any existing file at `filename`.
"""
function generate_example_input_file(filename::String=default_input_file_name;
                                     overwrite::Bool=false)

    if ispath(filename) && !overwrite
        error("$filename already exists. If you want to overwrite it, pass "
              * "`overwrite=true` to `generate_example_input_file()`.")
    end

    # Get example input, then convert to a String formatted as the contents of a TOML
    # file
    input_dict = generate_example_input_Dict()
    buffer = IOBuffer()
    TOML.print(buffer, input_dict)
    file_contents = String(take!(buffer))

    # Separate file_contents into individual lines
    file_contents = split(file_contents, "\n")

    # Add comment character to all values (i.e. skipping section headings)
    for (i, line) ∈ enumerate(file_contents)
        if !startswith(line, "[") && !(line == "")
            # Not a section heading, so add comment character
            file_contents[i] = "#" * line
        end
    end

    # Join back into single string
    file_contents = join(file_contents, "\n")

    # Write to output file
    open(filename, write=true, truncate=overwrite, append=false) do io
        print(io, file_contents)
    end

    return nothing
end

"""
    generate_example_input_Dict()

Create a Dict containing all the makie-post-processing options with default values
"""
function generate_example_input_Dict()
    original_input = deepcopy(input_dict)
    original_input_dfns = deepcopy(input_dict_dfns)

    # Set up input_dict and input_dict_dfns with all-default parameters
    setup_makie_post_processing_input!(OrderedDict{String,Any}())

    # Merge input_dict and input_dict_dfns, then convert to a String formatted as the
    # contents of a TOML file
    combined_input_dict = merge(input_dict_dfns, input_dict)

    # Restore original state of input_dict and input_dict_dfns
    clear_Dict!(input_dict)
    clear_Dict!(input_dict_dfns)
    merge!(input_dict, original_input)
    merge!(input_dict_dfns, original_input_dfns)

    return combined_input_dict
end

"""
    setup_makie_post_processing_input!(new_input_dict::AbstractDict{String,Any};
                                       run_info_moments=nothing,
                                       run_info_dfns=nothing)

Pass `input_file` to read the input from an input file other than
`$default_input_file_name`. You can also pass a `Dict{String,Any}` of options.

Set up input, storing in the global [`input_dict`](@ref) and [`input_dict_dfns`](@ref) to
be used in the various plotting and analysis functions.

The `run_info` that you are using (as returned by [`get_run_info`](@ref)) should be passed
to `run_info_moments` (if it contains only the moments), or `run_info_dfns` (if it also
contains the distributions functions), or both (if you have loaded both sets of output).
This allows default values to be set based on the grid sizes and number of time points
read from the output files.
"""
function setup_makie_post_processing_input! end

function setup_makie_post_processing_input!(input_file::String=default_input_file_name;
                                            run_info_moments=nothing,
                                            run_info_dfns=nothing)

    if isfile(input_file)
        new_input_dict = TOML.parsefile(input_file)
    else
        error("$input_file does not exist")
    end
    setup_makie_post_processing_input!(new_input_dict, run_info_moments=run_info_moments,
                                       run_info_dfns=run_info_dfns)

    return nothing
end

function setup_makie_post_processing_input!(new_input_dict::AbstractDict{String,Any};
                                            run_info_moments=nothing,
                                            run_info_dfns=nothing)
    convert_to_OrderedDicts!(new_input_dict)

    if isa(run_info_moments, Tuple)
        has_moments = any(ri !== nothing for ri ∈ run_info_moments)
    else
        has_moments = run_info_moments !== nothing
    end
    if isa(run_info_dfns, Tuple)
        has_dfns = any(ri !== nothing for ri ∈ run_info_dfns)
    else
        has_dfns = run_info_dfns !== nothing
    end

    if !has_moments && !has_dfns
        println("Neither `run_info_moments` nor `run_info_dfns` passed. Setting "
                * "defaults without using grid sizes")
    elseif !has_moments
        println("No run_info_moments, using run_info_dfns to set defaults")
        run_info_moments = run_info_dfns
        has_moments = true
    elseif !has_dfns
        println("No run_info_dfns, defaults for distribution function coordinate sizes "
                * "will be set to 1.")
    end

    _setup_single_input!(input_dict, new_input_dict, run_info_moments, false)
    _setup_single_input!(input_dict_dfns, new_input_dict, run_info_dfns, true)

    return nothing
end

# Utility function to reduce code duplication in setup_makie_post_processing_input!()
function _setup_single_input!(this_input_dict::OrderedDict{String,Any},
                              new_input_dict::AbstractDict{String,Any}, run_info,
                              dfns::Bool)
    # Remove all existing entries from this_input_dict
    clear_Dict!(this_input_dict)

    # Put entries from new_input_dict into this_input_dict
    merge!(this_input_dict, deepcopy(new_input_dict))

    if !isa(run_info, Tuple)
        # Make sure run_info is a Tuple
        run_info= (run_info,)
    end
    has_run_info = any(ri !== nothing for ri ∈ run_info)

    if has_run_info
        nt_unskipped_min = minimum(ri.nt_unskipped for ri in run_info
                                                   if ri !== nothing)
        nt_min = minimum(ri.nt for ri in run_info if ri !== nothing)
        nr_min = minimum(ri.r.n for ri in run_info if ri !== nothing)
        nz_min = minimum(ri.z.n for ri in run_info if ri !== nothing)
    else
        nt_unskipped_min = 1
        nt_min = 1
        nr_min = 1
        nz_min = 1
    end
    if dfns && has_run_info
        nvperp_min = minimum(ri.vperp.n for ri in run_info if ri !== nothing)
        nvpa_min = minimum(ri.vpa.n for ri in run_info if ri !== nothing)
        nvzeta_min = minimum(ri.vzeta.n for ri in run_info if ri !== nothing)
        nvr_min = minimum(ri.vr.n for ri in run_info if ri !== nothing)
        nvz_min = minimum(ri.vz.n for ri in run_info if ri !== nothing)
    else
        nvperp_min = 1
        nvpa_min = 1
        nvzeta_min = 1
        nvr_min = 1
        nvz_min = 1
    end

    # Whitelist of options that only apply at the global level, and should not be used
    # as defaults for per-variable options.
    # Notes:
    # - Don't allow setting "itime_*" and "itime_*_dfns" per-variable because we
    #   load time and time_dfns in run_info and these must use the same
    #   "itime_*"/"itime_*_dfns" setting as each variable.
    time_index_options = ("it0", "it0_dfns", "itime_min", "itime_max", "itime_skip",
                          "itime_min_dfns", "itime_max_dfns", "itime_skip_dfns")

    set_defaults_and_check_top_level!(this_input_dict;
       # Options that only apply at the global level (not per-variable)
       ################################################################
       # Options that provide the defaults for per-variable settings
       #############################################################
       colormap="reverse_deep",
       # Slice t to this value when making time-independent plots
       it0=nt_min,
       it0_dfns=nt_min,
       # Choose this species index when not otherwise specified
       is0=1,
       # Slice r to this value when making reduced dimensionality plots
       ir0=max(cld(nr_min, 3), 1),
       # Slice z to this value when making reduced dimensionality plots
       iz0=max(cld(nz_min, 3), 1),
       # Slice vperp to this value when making reduced dimensionality plots
       ivperp0=max(cld(nvperp_min, 3), 1),
       # Slice vpa to this value when making reduced dimensionality plots
       ivpa0=max(cld(nvpa_min, 3), 1),
       # Slice vzeta to this value when making reduced dimensionality plots
       ivzeta0=max(cld(nvzeta_min, 3), 1),
       # Slice vr to this value when making reduced dimensionality plots
       ivr0=max(cld(nvr_min, 3), 1),
       # Slice vz to this value when making reduced dimensionality plots
       ivz0=max(cld(nvz_min, 3), 1),
       # Time index to start from
       itime_min=1,
       # Time index to end at
       itime_max=nt_unskipped_min,
       # Load every `time_skip` time points for EM and moment variables, to save memory
       itime_skip=1,
       # Time index to start from for distribution functions
       itime_min_dfns=1,
       # Time index to end at for distribution functions
       itime_max_dfns=nt_unskipped_min,
       # Load every `time_skip` time points for distribution function variables, to save
       # memory
       itime_skip_dfns=1,
       plot_vs_r_t=true,
       plot_vs_z_t=true,
       animate_vs_z=true,
       animate_vs_r=true,
       animate_vs_z_r=true,
      )

    for variable_name ∈ all_variables
        set_defaults_and_check_section!(
            this_input_dict, variable_name;
            OrderedDict(Symbol(k)=>v for (k,v) ∈ this_input_dict
                        if !isa(v, AbstractDict) && !(k ∈ only_global_options))...)
    end


    return nothing
end

"""
    get_run_info(run_dir, restart_index=nothing; itime_min=1, itime_max=-1,
                 itime_skip=1, dfns=false)

Get file handles and other info for a single run

`run_dir` is the directory to read output from.

By default load data from moments files, pass `dfns=true` to load from distribution
functions files.

`restart_index` specifies which restart to read if there are multiple restarts. The
default (`nothing`) reads all restarts and concatenates them. An integer value reads the
restart with that index - `-1` indicates the latest restart (which does not have an
index).

The `itime_min`, `itime_max` and `itime_skip` options can be used to select only a slice
of time points when loading data. In `makie_post_process` these options are read from the
input (if they are set) before `get_run_info()` is called, so that the `run_info` returned
can be passed to [`setup_makie_post_processing_input!`](@ref), to be used for defaults for
the remaining options.
"""
function get_run_info(run_dir, restart_index=nothing; itime_min=1, itime_max=-1,
                      itime_skip=1, dfns=false)
    if !isdir(run_dir)
        error("$run_dir is not a directory")
    end

    # Normalise by removing any trailing slash - with a slash basename() would return an
    # empty string
    run_dir = rstrip(run_dir, '/')

    run_name = basename(run_dir)
    base_prefix = joinpath(run_dir, run_name)
    if restart_index === nothing
        # Find output files from all restarts in the directory
        counter = 1
        run_prefixes = Vector{String}()
        while true
            # Test if output files exist for this value of counter
            prefix_with_count = base_prefix * "_$counter"
            if length(glob(basename(prefix_with_count) * ".*.h5", dirname(prefix_with_count))) > 0 ||
                length(glob(basename(prefix_with_count) * ".*.cdf", dirname(prefix_with_count))) > 0

                push!(run_prefixes, prefix_with_count)
            else
                # No more output files found
                break
            end
            counter += 1
        end
        # Add the final run which does not have a '_$counter' suffix
        push!(run_prefixes, base_prefix)
        run_prefixes = tuple(run_prefixes...)
    elseif restart_index == -1
        run_prefixes = (base_prefix,)
    elseif restart_index > 0
        run_prefixes = (base_prefix * "_$restart_index",)
    else
        error("Invalid restart_index=$restart_index")
    end

    if dfns
        ext = "dfns"
    else
        ext = "moments"
    end

    has_data = all(length(glob(basename(p) * ".$ext*.h5", dirname(p))) > 0
                   for p ∈ run_prefixes)
    if !has_data
        println("No $ext data found for $run_prefixes, skipping $ext")
        return nothing
    end

    fids0 = Tuple(open_readonly_output_file(r, ext, printout=false)
                         for r ∈ run_prefixes)
    nblocks = Tuple(load_block_data(f)[1] for f ∈ fids0)
    if all(n == 1 for n ∈ nblocks)
        # Did not use distributed memory, or used parallel_io
        parallel_io = true
    else
        parallel_io = false
    end

    nt_unskipped, time, restarts_nt = load_time_data(fids0)
    if itime_max <= 0
        itime_max = nt_unskipped
    end
    time = time[itime_min:itime_skip:itime_max]
    nt = length(time)

    # Get input and coordinates from the final restart
    file_final_restart = fids0[end]

    input = load_input(file_final_restart)

    # obtain input options from moment_kinetics_input.jl
    # and check input to catch errors
    io_input, evolve_moments, t_input, z_input, r_input, vpa_input, vperp_input,
        gyrophase_input, vz_input, vr_input, vzeta_input, composition, species,
        collisions, geometry, drive_input, num_diss_params, manufactured_solns_input =
        mk_input(input)

    n_ion_species, n_neutral_species = load_species_data(file_final_restart)
    evolve_density, evolve_upar, evolve_ppar = load_mk_options(file_final_restart)

    z_local, z_local_spectral = load_coordinate_data(file_final_restart, "z")
    r_local, r_local_spectral = load_coordinate_data(file_final_restart, "r")
    r, r_spectral, z, z_spectral = construct_global_zr_coords(r_local, z_local)

    if dfns
        vperp, vperp_spectral = load_coordinate_data(file_final_restart, "vperp")
        vpa, vpa_spectral = load_coordinate_data(file_final_restart, "vpa")

        if n_neutral_species > 0
            vzeta, vzeta_spectral = load_coordinate_data(file_final_restart, "vzeta")
            vr, vr_spectral = load_coordinate_data(file_final_restart, "vr")
            vz, vz_spectral = load_coordinate_data(file_final_restart, "vz")
        else
            dummy_adv_input = advection_input("default", 1.0, 0.0, 0.0)
            dummy_comm = MPI.COMM_NULL
            dummy_input = grid_input("dummy", 1, 1, 1, 1, 0, 1.0,
                                     "chebyshev_pseudospectral", "", "periodic",
                                     dummy_adv_input, dummy_comm)
            vzeta, vzeta_spectral = define_coordinate(dummy_input)
            vr, vr_spectral = define_coordinate(dummy_input)
            vz, vz_spectral = define_coordinate(dummy_input)
        end
    end

    if parallel_io
        files = fids0
    else
        # Don't keep open files as read_distributed_zr_data!(), etc. open the files
        # themselves
        files = run_prefixes
    end

    if dfns
        return (run_name=run_name, run_prefix=base_prefix, parallel_io=parallel_io,
                ext=ext, nblocks=nblocks, files=files, input=input,
                n_ion_species=n_ion_species, n_neutral_species=n_neutral_species,
                evolve_moments=evolve_moments, composition=composition, species=species,
                collisions=collisions, geometry=geometry, drive_input=drive_input,
                num_diss_params=num_diss_params,
                manufactured_solns_input=manufactured_solns_input, nt=nt,
                nt_unskipped=nt_unskipped, restarts_nt=restarts_nt, itime_min=itime_min,
                itime_skip=itime_skip, itime_max=itime_max, time=time, r=r, z=z,
                vperp=vperp, vpa=vpa, vzeta=vzeta, vr=vr, vz=vz, r_local=r_local,
                z_local=z_local, r_spectral=r_spectral, z_spectral=z_spectral,
                vperp_spectral=vperp_spectral, vpa_spectral=vpa_spectral,
                vzeta_spectral=vzeta_spectral, vr_spectral=vr_spectral,
                vz_spectral=vz_spectral, dfns=dfns)
    else
        return (run_name=run_name, run_prefix=base_prefix, parallel_io=parallel_io,
                ext=ext, nblocks=nblocks, files=files, input=input,
                n_ion_species=n_ion_species, n_neutral_species=n_neutral_species,
                evolve_moments=evolve_moments, composition=composition, species=species,
                collisions=collisions, geometry=geometry, drive_input=drive_input,
                num_diss_params=num_diss_params,
                manufactured_solns_input=manufactured_solns_input, nt=nt,
                nt_unskipped=nt_unskipped, restarts_nt=restarts_nt, itime_min=itime_min,
                itime_skip=itime_skip, itime_max=itime_max, time=time, r=r, z=z,
                r_local=r_local, z_local=z_local, r_spectral=r_spectral,
                z_spectral=z_spectral, dfns=dfns)
    end
end

"""
    postproc_load_variable(run_info, variable_name; it=nothing, is=nothing,
                           ir=nothing, iz=nothing, ivperp=nothing, ivpa=nothing,
                           ivzeta=nothing, ivr=nothing, ivz=nothing)

Load a variable

`run_info` is the information about a run returned by [`get_run_info`](@ref).

`variable_name` is the name of the variable to load.

The keyword arguments `it`, `is`, `ir`, `iz`, `ivperp`, `ivpa`, `ivzeta`, `ivr`, and `ivz`
can be set to an integer or a range (e.g. `3:8` or `3:2:8`) to select subsets of the data.
Only the data for the subset requested will be loaded from the output file (mostly - when
loading fields or moments from runs which used `parallel_io = false`, the full array will
be loaded and then sliced).
"""
function postproc_load_variable(run_info, variable_name; it=nothing, is=nothing,
                                ir=nothing, iz=nothing, ivperp=nothing, ivpa=nothing,
                                ivzeta=nothing, ivr=nothing, ivz=nothing)
    nt = run_info.nt

    if it === nothing
        it = run_info.itime_min:run_info.itime_skip:run_info.itime_max
    elseif isa(it, mk_int)
        nt = 1
    else
        nt = length(it)
    end
    if is === nothing
        # Can't use 'n_species' in a similar way to the way we treat other dims, because
        # we don't know here if the variable is for ions or neutrals.
        # Use Colon operator `:` when slice argument is `nothing` as when we pass that as
        # an 'index', it selects the whole dimension. Brackets are needed around the `:`
        # when assigning it to variables, etc. to avoid an error "LoadError: syntax:
        # newline not allowed after ":" used for quoting".
        is = (:)
    elseif isa(is, mk_int)
        nspecies = 1
    else
        nspecies = length(is)
    end
    if ir === nothing
        nr = run_info.r.n
        ir = 1:nr
    elseif isa(ir, mk_int)
        nr = 1
    else
        nr = length(ir)
    end
    if iz === nothing
        nz = run_info.z.n
        iz = 1:nz
    elseif isa(iz, mk_int)
        nz = 1
    else
        nz = length(iz)
    end
    if ivperp === nothing
        if :vperp ∈ keys(run_info)
            # v-space coordinates only present if run_info contains distribution functions
            nvperp = run_info.vperp.n
            ivperp = 1:nvperp
        else
            nvperp = nothing
            ivperp = nothing
        end
    elseif isa(ivperp, mk_int)
        nvperp = 1
    else
        nvperp = length(ivperp)
    end
    if ivpa === nothing
        if :vpa ∈ keys(run_info)
            # v-space coordinates only present if run_info contains distribution functions
            nvpa = run_info.vpa.n
            ivpa = 1:nvpa
        else
            nvpa = nothing
            ivpa = nothing
        end
    elseif isa(ivpa, mk_int)
        nvpa = 1
    else
        nvpa = length(ivpa)
    end
    if ivzeta === nothing
        if :vzeta ∈ keys(run_info)
            # v-space coordinates only present if run_info contains distribution functions
            nvzeta = run_info.vzeta.n
            ivzeta = 1:nvzeta
        else
            nvzeta = nothing
            ivzeta = nothing
        end
    elseif isa(ivzeta, mk_int)
        nvzeta = 1
    else
        nvzeta = length(ivzeta)
    end
    if ivr === nothing
        if :vr ∈ keys(run_info)
            # v-space coordinates only present if run_info contains distribution functions
            nvr = run_info.vr.n
            ivr = 1:nvr
        else
            nvr = nothing
            ivr = nothing
        end
    elseif isa(ivr, mk_int)
        nvr = 1
    else
        nvr = length(ivr)
    end
    if ivz === nothing
        if :vz ∈ keys(run_info)
            # v-space coordinates only present if run_info contains distribution functions
            nvz = run_info.vz.n
            ivz = 1:nvz
        else
            nvz = nothing
            ivz = nothing
        end
    elseif isa(ivz, mk_int)
        nvz = 1
    else
        nvz = length(ivz)
    end

    if run_info.parallel_io
        # Get HDF5/NetCDF variables directly and load slices
        variable = Tuple(get_group(f, "dynamic_data")[variable_name]
                         for f ∈ run_info.files)
        nd = ndims(variable[1])

        if nd == 3
            # EM variable with dimensions (z,r,t)
            dims = Vector{mk_int}()
            !isa(iz, mk_int) && push!(dims, nz)
            !isa(ir, mk_int) && push!(dims, nr)
            !isa(it, mk_int) && push!(dims, nt)
            result = allocate_float(dims...)
        elseif nd == 4
            # moment variable with dimensions (z,r,s,t)
            # Get nspecies from the variable, not from run_info, because it might be
            # either ion or neutral
            dims = Vector{mk_int}()
            !isa(iz, mk_int) && push!(dims, nz)
            !isa(ir, mk_int) && push!(dims, nr)
            if is === (:)
                nspecies = size(variable[1], 3)
                push!(dims, nspecies)
            elseif !isa(is, mk_int)
                push!(dims, nspecies)
            end
            !isa(it, mk_int) && push!(dims, nt)
            result = allocate_float(dims...)
        elseif nd == 6
            # ion distribution function variable with dimensions (vpa,vperp,z,r,s,t)
            nspecies = size(variable[1], 5)
            dims = Vector{mk_int}()
            !isa(ivpa, mk_int) && push!(dims, nvpa)
            !isa(ivperp, mk_int) && push!(dims, nvperp)
            !isa(iz, mk_int) && push!(dims, nz)
            !isa(ir, mk_int) && push!(dims, nr)
            if is === (:)
                nspecies = size(variable[1], 3)
                push!(dims, nspecies)
            elseif !isa(is, mk_int)
                push!(dims, nspecies)
            end
            !isa(it, mk_int) && push!(dims, nt)
            result = allocate_float(dims...)
        elseif nd == 7
            # neutral distribution function variable with dimensions (vz,vr,vzeta,z,r,s,t)
            nspecies = size(variable[1], 6)
            dims = Vector{mk_int}()
            !isa(ivz, mk_int) && push!(dims, nvz)
            !isa(ivr, mk_int) && push!(dims, nvr)
            !isa(ivzeta, mk_int) && push!(dims, nvzeta)
            !isa(iz, mk_int) && push!(dims, nz)
            !isa(ir, mk_int) && push!(dims, nr)
            if is === (:)
                nspecies = size(variable[1], 3)
                push!(dims, nspecies)
            elseif !isa(is, mk_int)
                push!(dims, nspecies)
            end
            !isa(it, mk_int) && push!(dims, nt)
            result = allocate_float(dims...)
        else
            error("Unsupported number of dimensions ($nd) for '$variable_name'.")
        end

        local_it_start = 1
        global_it_start = 1
        for v ∈ variable
            # For restarts, the first time point is a duplicate of the last time
            # point of the previous restart. Use `offset` to skip this point.
            offset = local_it_start == 1 ? 0 : 1
            local_nt = size(v, nd) - offset
            local_it_end = local_it_start+local_nt-1

            if isa(it, mk_int)
                tind = it - local_it_start + 1
                if tind < 1
                    error("Trying to select time index before the beginning of this "
                          * "restart, should have finished already")
                elseif tind <= local_nt
                    # tind is within this restart's time range, so get result
                    if nd == 3
                        result .= v[iz,ir,tind]
                    elseif nd == 4
                        result .= v[iz,ir,is,tind]
                    elseif nd == 6
                        result .= v[ivpa,ivperp,iz,ir,is,tind]
                    elseif nd == 7
                        result .= v[ivz,ivr,ivzeta,iz,ir,is,tind]
                    else
                        error("Unsupported combination nd=$nd, ir=$ir, iz=$iz, ivperp=$ivperp "
                              * "ivpa=$ivpa, ivzeta=$ivzeta, ivr=$ivr, ivz=$ivz.")
                    end

                    # Already got the data for `it`, so end loop
                    break
                end
            else
                tinds = collect(i - local_it_start + 1 + offset for i ∈ it
                                if local_it_start <= i <= local_it_end)
                # Convert tinds to slice, as we know the spacing is constant
                if length(tinds) == 0
                    # Nothing to do in this file
                    continue
                elseif length(tinds) > 1
                    tstep = tinds[2] - tinds[begin]
                else
                    tstep = 1
                end
                tinds = tinds[begin]:tstep:tinds[end]
                global_it_end = global_it_start + length(tinds) - 1

                if nd == 3
                    selectdim(result, ndims(result), global_it_start:global_it_end) .= v[iz,ir,tinds]
                elseif nd == 4
                    selectdim(result, ndims(result), global_it_start:global_it_end) .= v[iz,ir,is,tinds]
                elseif nd == 6
                    selectdim(result, ndims(result), global_it_start:global_it_end) .= v[ivpa,ivperp,iz,ir,is,tinds]
                elseif nd == 7
                    selectdim(result, ndims(result), global_it_start:global_it_end) .= v[ivz,ivr,ivzeta,iz,ir,is,tinds]
                else
                    error("Unsupported combination nd=$nd, ir=$ir, iz=$iz, ivperp=$ivperp "
                          * "ivpa=$ivpa, ivzeta=$ivzeta, ivr=$ivr, ivz=$ivz.")
                end

                global_it_start = global_it_end + 1
            end

            local_it_start = local_it_end + 1
        end
    else
        # Use existing distributed I/O loading functions
        if variable_name ∈ em_variables
            nd = 3
        elseif variable_name ∈ ion_dfn_variables
            nd = 6
        elseif variable_name ∈ neutral_dfn_variables
            nd = 7
        else
            # Ion or neutral moment variable
            nd = 4
        end

        if nd == 3
            result = allocate_float(run_info.z.n, run_info.r.n, run_info.nt)
            read_distributed_zr_data!(result, variable_name, run_info.files,
                                      run_info.ext, run_info.nblocks, run_info.z_local.n,
                                      run_info.r_local.n, run_info.itime_skip)
            result = result[iz,ir,it]
        elseif nd == 4
            # If we ever have neutrals included but n_neutral_species != n_ion_species,
            # then this will fail - in that case would need some way to specify that we
            # need to read a neutral moment variable rather than an ion moment variable
            # here.
            result = allocate_float(run_info.z.n, run_info.r.n, run_info.n_ion_species,
                                    run_info.nt)
            read_distributed_zr_data!(result, variable_name, run_info.files,
                                      run_info.ext, run_info.nblocks, run_info.z_local.n,
                                      run_info.r_local.n, run_info.itime_skip)
            result = result[iz,ir,is,it]
        elseif nd === 6
            result = load_distributed_charged_pdf_slice(run_info.files, run_info.nblocks,
                                                        it, run_info.n_ion_species,
                                                        run_info.r_local,
                                                        run_info.z_local, run_info.vperp,
                                                        run_info.vpa;
                                                        is=(is === (:) ? nothing : is),
                                                        ir=ir, iz=iz, ivperp=ivperp,
                                                        ivpa=ivpa)
        elseif nd === 7
            result = load_distributed_neutral_pdf_slice(run_info.files, run_info.nblocks,
                                                        it, run_info.n_ion_species,
                                                        run_info.r_local,
                                                        run_info.z_local, run_info.vzeta,
                                                        run_info.vr, run_info.vz;
                                                        isn=(is === (:) ? nothing : is),
                                                        ir=ir, iz=iz, ivzeta=ivzeta,
                                                        ivr=ivr, ivz=ivz)
        end
    end

    return result
end

"""
    plots_for_variable(run_info, variable_name; plot_prefix)

Make plots for the EM field or moment variable `variable_name`.

Which plots to make are determined by the settings in the section of the input whose
heading is the variable name.

`run_info` is the information returned by [`get_run_info`](@ref).

`plot_prefix` is required and gives the path and prefix for plots to be saved to. They
will be saved with the format `plot_prefix<some_identifying_string>.pdf` for plots and
`plot_prefix<some_identifying_string>.gif`, etc. for animations.

`is_1D` and/or `is_1V` can be passed to allow the function to skip some plots that do not
make sense for 1D or 1V simulations (regardless of the settings).
"""
function plots_for_variable(run_info, variable_name; plot_prefix, is_1D=false,
                            is_1V=false)
    input = Dict_to_NamedTuple(input_dict[variable_name])

    # test if any plot is needed
    if any(v for (k,v) in pairs(input) if
           startswith(String(k), "plot") || startswith(String(k), "animate"))
        println("Making plots for $variable_name")
        flush(stdout)

        if variable_name == "temperature"
            vth = Tuple(postproc_load_variable(ri, "thermal_speed")
                        for ri ∈ run_info)
            variable = Tuple(v.^2 for v ∈ vth)
        elseif variable_name == "temperature_neutral"
            vth = Tuple(postproc_load_variable(ri, "thermal_speed_neutral")
                        for ri ∈ run_info)
            variable = Tuple(v.^2 for v ∈ vth)
        else
            variable = Tuple(postproc_load_variable(ri, variable_name)
                             for ri ∈ run_info)
        end
        if variable_name ∈ em_variables
            species_indices = (nothing,)
        elseif variable_name ∈ neutral_moment_variables ||
               variable_name ∈ neutral_dfn_variables
            species_indices = 1:maximum(ri.n_neutral_species for ri ∈ run_info)
        else
            species_indices = 1:maximum(ri.n_ion_species for ri ∈ run_info)
        end
        for is ∈ species_indices
            if is !== nothing
                variable_prefix = plot_prefix * variable_name * "_spec$(is)_"
            else
                variable_prefix = plot_prefix * variable_name * "_"
            end
            if variable_name == "Er" && is_1D
                # Skip if there is no r-dimension
                continue
            end
            if !is_1D && input.plot_vs_r_t
                plot_vs_r_t(run_info, variable_name, is=is, data=variable, input=input,
                            outfile=variable_prefix * "vs_r_t.pdf")
            end
            if input.plot_vs_z_t
                plot_vs_z_t(run_info, variable_name, is=is, data=variable, input=input,
                            outfile=variable_prefix * "vs_z_t.pdf")
            end
            if !is_1D && input.plot_vs_r
                plot_vs_r(run_info, variable_name, is=is, data=variable, input=input,
                          outfile=variable_prefix * "vs_r.pdf")
            end
            if input.plot_vs_z
                plot_vs_z(run_info, variable_name, is=is, data=variable, input=input,
                          outfile=variable_prefix * "vs_z.pdf")
            end
            if input.animate_vs_z
                animate_vs_z(run_info, variable_name, is=is, data=variable, input=input,
                             outfile=variable_prefix * "vs_z.gif")
            end
            if !is_1D && input.animate_vs_r
                animate_vs_r(run_info, variable_name, is=is, data=variable, input=input,
                             outfile=variable_prefix * "vs_r.gif")
            end
            if !is_1D && input.animate_vs_z_r
                animate_vs_z_r(run_info, variable_name, is=is, data=variable, input=input,
                               outfile=variable_prefix * "vs_r.gif")
            end
        end
    end

    return nothing
end

# Generate 1d plot functions for each dimension
for dim ∈ one_dimension_combinations
    function_name_str = "plot_vs_$dim"
    function_name = Symbol(function_name_str)
    spaces = " " ^ length(function_name_str)
    dim_str = String(dim)
    if dim == :t
        dim_grid = :( run_info.time )
    else
        dim_grid = :( run_info.$dim.grid )
    end
    idim = Symbol(:i, dim)
    eval(quote
             export $function_name

             """
             function $($function_name_str)(run_info::Tuple, var_name; is=1, data=nothing,
                      $($spaces)input=nothing, outfile=nothing, yscale=nothing,
                      $($spaces)transform=identity, it=nothing, ir=nothing, iz=nothing,
                      $($spaces)ivperp=nothing, ivpa=nothing, ivzeta=nothing, ivr=nothing,
                      $($spaces)ivz=nothing, kwargs...)
             function $($function_name_str)(run_info, var_name; is=1, data=nothing,
                      $($spaces)input=nothing, ax=nothing, label=nothing,
                      $($spaces)outfile=nothing, yscale=nothing, transform=identity,
                      $($spaces)it=nothing, ir=nothing, iz=nothing, ivperp=nothing,
                      $($spaces)ivpa=nothing, ivzeta=nothing, ivr=nothing, ivz=nothing,
                      $($spaces)kwargs...)

             Plot `var_name` from the run(s) represented by `run_info` (as returned by
             [`get_run_info`](@ref)) vs $($dim_str).

             If a Tuple of `run_info` is passed, the plots from each run are overlayed on
             the same axis, and a legend is added.

             `it`, `is`, `ir`, `iz`, `ivperp`, `ivpa`, `ivzeta`, `ivr`, and `ivz` can be
             used to select different indices (for non-plotted dimensions) or range (for
             the plotted dimension) to use.

             If `outfile` is given, the plot will be saved to a file with that name. The
             suffix determines the file type.

             `yscale` can be used to set the scaling function for the y-axis. Options are
             `identity`, `log`, `log2`, `log10`, `sqrt`, `Makie.logit`,
             `Makie.pseudolog10` and `Makie.Symlog10`. `transform` is a function that is
             applied element-by-element to the data before it is plotted. For example when
             using a log scale on data that may contain some negative values it might be
             useful to pass `transform=abs` (to plot the absolute value) or
             `transform=positive_or_nan` (to ignore any negative or zero values).

             Extra `kwargs` are passed to Makie's `lines!() function`.

             When a single `run_info` is passed, `label` can be used to set the label for
             the line created by this plot, which would be used if it is added to a
             `Legend`.

             When a single `run_info` is passed, an `Axis` can be passed to `ax`. If it
             is, the plot will be added to `ax`.

             By default the data for the variable is loaded from the output represented by
             `run_info`. The data can optionally be passed to `data` if you have already
             loaded it.

             Returns the `Figure`, unless `ax` was passed in which case the object
             returned by Makie's `lines!()` function is returned.

             By default relevant settings are read from the `var_name` section of
             [`input_dict_dfns`](@ref) (if output that has distribution functions is being
             read) or [`input_dict`](@ref) (otherwise). The settings can also be passed as
             an `AbstractDict` or `NamedTuple` via the `input` argument.  Sometimes
             needed, for example if `var_name` is not present in `input_dict` (in which
             case you would have had to create the array to be plotted and pass it to
             `data`).
             """
             function $function_name end

             function $function_name(run_info::Tuple, var_name; is=1, data=nothing,
                                     input=nothing, outfile=nothing, yscale=nothing,
                                     transform=identity, kwargs...)

                 try
                     if data === nothing
                         data = Tuple(nothing for _ in run_info)
                     end

                     n_runs = length(run_info)

                     fig, ax = get_1d_ax(xlabel="$($dim_str)",
                                         ylabel=get_variable_symbol(var_name),
                                         yscale=yscale)
                     for (d, ri) ∈ zip(data, run_info)
                         $function_name(ri, var_name, is=is, data=d, input=input, ax=ax,
                                        transform=transform, label=ri.run_name, kwargs...)
                     end

                     if n_runs > 1
                         put_legend_above(fig, ax)
                     end

                     if outfile !== nothing
                         save(outfile, fig)
                     end
                     return fig
                 catch e
                     println("$($function_name_str) failed for $var_name, is=$is. Error was $e")
                     return nothing
                 end
             end

             function $function_name(run_info, var_name; is=1, data=nothing,
                                     input=nothing, ax=nothing, label=nothing,
                                     outfile=nothing, it=nothing, ir=nothing, iz=nothing,
                                     ivperp=nothing, ivpa=nothing, ivzeta=nothing,
                                     ivr=nothing, ivz=nothing, kwargs...)
                 if input === nothing
                     if run_info.dfns
                         input = input_dict_dfns[var_name]
                     else
                         input = input_dict[var_name]
                     end
                 end
                 if isa(input, AbstractDict)
                     input = Dict_to_NamedTuple(input)
                 end
                 if data === nothing
                     dim_slices = get_dimension_slice_indices($(QuoteNode(dim));
                                                              input=input, it=it, is=is,
                                                              ir=ir, iz=iz, ivperp=ivperp,
                                                              ivpa=ivpa, ivzeta=ivzeta,
                                                              ivr=ivr, ivz=ivz)
                     data = postproc_load_variable(run_info, var_name; dim_slices...)
                 else
                     data = select_slice(data, $(QuoteNode(dim)); input=input, it=it,
                                         is=is, ir=ir, iz=iz, ivperp=ivperp, ivpa=ivpa,
                                         ivzeta=ivzeta, ivr=ivr, ivz=ivz)
                 end

                 x = $dim_grid
                 if $idim !== nothing
                     x = x[$idim]
                 end
                 fig = plot_1d(x, data; xlabel="$($dim_str)",
                               ylabel=get_variable_symbol(var_name), label=label, ax=ax,
                               kwargs...)

                 if outfile !== nothing
                     if fig === nothing
                         error("When `outfile` is passed to save the plot, must either pass both "
                               * "`fig` and `ax` or neither. Only `ax` was passed.")
                     end
                     save(outfile, fig)
                 end

                 return fig
             end
         end)
end

# Generate 2d plot functions for all combinations of dimensions
for (dim1, dim2) ∈ two_dimension_combinations
    function_name_str = "plot_vs_$(dim2)_$(dim1)"
    function_name = Symbol(function_name_str)
    spaces = " " ^ length(function_name_str)
    dim1_str = String(dim1)
    dim2_str = String(dim2)
    if dim1 == :t
        dim1_grid = :( run_info.time )
    else
        dim1_grid = :( run_info.$dim1.grid )
    end
    dim2_grid = :( run_info.$dim2.grid )
    idim1 = Symbol(:i, dim1)
    idim2 = Symbol(:i, dim2)
    eval(quote
             export $function_name

             """
             function $($function_name_str)(run_info::Tuple, var_name; is=1, data=nothing,
                      $($spaces)input=nothing, outfile=nothing, colorscale=identity,
                      $($spaces)transform=identity, it=nothing, ir=nothing, iz=nothing,
                      $($spaces)ivperp=nothing, ivpa=nothing, ivzeta=nothing, ivr=nothing,
                      $($spaces)ivz=nothing, kwargs...)
             function $($function_name_str)(run_info, var_name; is=1, data=nothing,
                      $($spaces)input=nothing, ax=nothing,
                      $($spaces)colorbar_place=nothing, title=nothing,
                      $($spaces)outfile=nothing, colorscale=identity, transform=identity,
                      $($spaces)it=nothing, ir=nothing, iz=nothing, ivperp=nothing,
                      $($spaces)ivpa=nothing, ivzeta=nothing, ivr=nothing, ivz=nothing,
                      $($spaces)kwargs...)

             Plot `var_name` from the run(s) represented by `run_info` (as returned by
             [`get_run_info`](@ref))vs $($dim1_str) and $($dim2_str).

             If a Tuple of `run_info` is passed, the plots from each run are displayed in
             a horizontal row, and the subtitle for each subplot is the 'run name'.

             `it`, `is`, `ir`, `iz`, `ivperp`, `ivpa`, `ivzeta`, `ivr`, and `ivz` can be
             used to select different indices (for non-plotted dimensions) or range (for
             the plotted dimension) to use.

             If `outfile` is given, the plot will be saved to a file with that name. The
             suffix determines the file type.

             `colorscale` can be used to set the scaling function for the colors. Options
             are `identity`, `log`, `log2`, `log10`, `sqrt`, `Makie.logit`,
             `Makie.pseudolog10` and `Makie.Symlog10`. `transform` is a function that is
             applied element-by-element to the data before it is plotted. For example when
             using a log scale on data that may contain some negative values it might be
             useful to pass `transform=abs` (to plot the absolute value) or
             `transform=positive_or_nan` (to ignore any negative or zero values).

             Extra `kwargs` are passed to Makie's `heatmap!() function`.

             When a single `run_info` is passed, `title` can be used to set the title for
             the (sub-)plot.

             When a single `run_info` is passed, an `Axis` can be passed to `ax`. If it
             is, the plot will be added to `ax`. A colorbar will be created in
             `colorbar_place` if it is given a `GridPosition`.

             By default the data for the variable is loaded from the output represented by
             `run_info`. The data can optionally be passed to `data` if you have already
             loaded it.

             Returns the `Figure`, unless `ax` was passed in which case the object
             returned by Makie's `heatmap!()` function is returned.

             By default relevant settings are read from the `var_name` section of
             [`input_dict_dfns`](@ref) (if output that has distribution functions is being
             read) or [`input_dict`](@ref) (otherwise). The settings can also be passed as
             an `AbstractDict` or `NamedTuple` via the `input` argument.  Sometimes
             needed, for example if `var_name` is not present in `input_dict` (in which
             case you would have had to create the array to be plotted and pass it to
             `data`).
             """
             function $function_name end

             function $function_name(run_info::Tuple, var_name; is=1, data=nothing,
                                     input=nothing, outfile=nothing, transform=identity,
                                     kwargs...)

                 try
                     if data === nothing
                         data = Tuple(nothing for _ in run_info)
                     end
                     fig, ax, colorbar_places = get_2d_ax(length(run_info),
                                                          title=get_variable_symbol(var_name))
                     for (d, ri, a, cp) ∈ zip(data, run_info, ax, colorbar_places)
                         $function_name(ri, var_name; is=is, data=d, input=input, ax=a,
                                        transform=transform, colorbar_place=cp,
                                        title=ri.run_name, kwargs...)
                     end

                     if outfile !== nothing
                         save(outfile, fig)
                     end
                     return fig
                 catch e
                     println("$($function_name_str) failed for $var_name, is=$is. Error was $e")
                     return nothing
                 end
             end

             function $function_name(run_info, var_name; is=1, data=nothing,
                                     input=nothing, ax=nothing,
                                     colorbar_place=nothing, title=nothing,
                                     outfile=nothing, it=nothing, ir=nothing, iz=nothing,
                                     ivperp=nothing, ivpa=nothing, ivzeta=nothing,
                                     ivr=nothing, ivz=nothing, kwargs...)
                 if input === nothing
                     if run_info.dfns
                         input = input_dict_dfns[var_name]
                     else
                         input = input_dict[var_name]
                     end
                 end
                 if isa(input, AbstractDict)
                     input = Dict_to_NamedTuple(input)
                 end
                 if data === nothing
                     dim_slices = get_dimension_slice_indices($(QuoteNode(dim1)),
                                                              $(QuoteNode(dim2));
                                                              input=input, it=it, is=is,
                                                              ir=ir, iz=iz, ivperp=ivperp,
                                                              ivpa=ivpa, ivzeta=ivzeta,
                                                              ivr=ivr, ivz=ivz)
                     data = postproc_load_variable(run_info, var_name; dim_slices...)
                 else
                     data = select_slice(data, $(QuoteNode(dim2)), $(QuoteNode(dim1));
                                         input=input, it=it, is=is, ir=ir, iz=iz,
                                         ivperp=ivperp, ivpa=ivpa, ivzeta=ivzeta, ivr=ivr,
                                         ivz=ivz)
                 end
                 if input === nothing
                     colormap = "reverse_deep"
                 else
                     colormap = input.colormap
                 end
                 if title === nothing
                     title = get_variable_symbol(var_name)
                 end

                 x = $dim2_grid
                 if $idim2 !== nothing
                     x = x[$idim2]
                 end
                 y = $dim1_grid
                 if $idim1 !== nothing
                     y = y[$idim1]
                 end
                 fig = plot_2d(x, y, data; xlabel="$($dim2_str)", ylabel="$($dim1_str)",
                               title=title, ax=ax, colorbar_place=colorbar_place,
                               colormap=colormap, kwargs...)

                 if outfile !== nothing
                     if fig === nothing
                         error("When `outfile` is passed to save the plot, must either pass both "
                               * "`fig` and `ax` or neither. Only `ax` was passed.")
                     end
                     save(outfile, fig)
                 end

                 return fig
             end
         end)
end

# Generate 1d animation functions for each dimension
for dim ∈ one_dimension_combinations_no_t
    function_name_str = "animate_vs_$dim"
    function_name = Symbol(function_name_str)
    spaces = " " ^ length(function_name_str)
    dim_str = String(dim)
    dim_grid = :( run_info.$dim.grid )
    idim = Symbol(:i, dim)
    eval(quote
             export $function_name

             """
             function $($function_name_str)(run_info::Tuple, var_name; is=1, data=nothing,
                      $($spaces)input=nothing, outfile=nothing, yscale=nothing,
                      $($spaces)transform=identity, ylims=nothing, it=nothing, ir=nothing,
                      $($spaces)iz=nothing, ivperp=nothing, ivpa=nothing, ivzeta=nothing,
                      $($spaces)ivr=nothing, ivz=nothing, kwargs...)
             function $($function_name_str)(run_info, var_name; is=1, data=nothing,
                      $($spaces)input=nothing, frame_index=nothing, ax=nothing,
                      $($spaces)fig=nothing, outfile=nothing, yscale=nothing,
                      $($spaces)transform=identity, ylims=nothing, it=nothing, ir=nothing,
                      $($spaces)iz=nothing, ivperp=nothing, ivpa=nothing, ivzeta=nothing,
                      $($spaces)ivr=nothing, ivz=nothing, kwargs...)

             Animate `var_name` from the run(s) represented by `run_info` (as returned by
             [`get_run_info`](@ref))vs $($dim_str).

             If a Tuple of `run_info` is passed, the animations from each run are
             overlayed on the same axis, and a legend is added.

             `it`, `is`, `ir`, `iz`, `ivperp`, `ivpa`, `ivzeta`, `ivr`, and `ivz` can be
             used to select different indices (for non-plotted dimensions) or range (for
             the plotted dimension) to use.

             `ylims` can be passed a Tuple (ymin, ymax) to set the y-axis limits. By
             default the minimum and maximum of the data (over all time points) will be
             used.

             `yscale` can be used to set the scaling function for the y-axis. Options are
             `identity`, `log`, `log2`, `log10`, `sqrt`, `Makie.logit`,
             `Makie.pseudolog10` and `Makie.Symlog10`. `transform` is a function that is
             applied element-by-element to the data before it is plotted. For example when
             using a log scale on data that may contain some negative values it might be
             useful to pass `transform=abs` (to plot the absolute value) or
             `transform=positive_or_nan` (to ignore any negative or zero values).

             Extra `kwargs` are passed to Makie's `lines!() function`.

             When a single `run_info` is passed, an `Axis` can be passed to `ax`. If it
             is, the plot will be added to `ax`.

             `outfile` is required for animations unless `ax` is passed. The animation
             will be saved to a file named `outfile`.  The suffix determines the file
             type. If both `outfile` and `ax` are passed, then the `Figure` containing
             `ax` must be passed to `fig` to allow the animation to be saved.

             By default the data for the variable is loaded from the output represented by
             `run_info`. The data can optionally be passed to `data` if you have already
             loaded it.

             Returns the `Figure`, unless `ax` was passed in which case returns `nothing`.

             By default relevant settings are read from the `var_name` section of
             [`input_dict_dfns`](@ref) (if output that has distribution functions is being
             read) or [`input_dict`](@ref) (otherwise). The settings can also be passed as
             an `AbstractDict` or `NamedTuple` via the `input` argument.  Sometimes
             needed, for example if `var_name` is not present in `input_dict` (in which
             case you would have had to create the array to be plotted and pass it to
             `data`).
             """
             function $function_name end

             function $function_name(run_info::Tuple, var_name; is=1, data=nothing,
                                     input=nothing, outfile=nothing, yscale=nothing,
                                     ylims=nothing, kwargs...)

                 try
                     if data === nothing
                         data = Tuple(nothing for _ in run_info)
                     end
                     if outfile === nothing
                         error("`outfile` is required for $($function_name_str)")
                     end

                     n_runs = length(run_info)

                     fig, ax = get_1d_ax(xlabel="$($dim_str)",
                                         ylabel=get_variable_symbol(var_name),
                                         yscale=yscale)
                     frame_index = Observable(1)

                     for (d, ri) ∈ zip(data, run_info)
                         $function_name(ri, var_name; is=is, data=d, input=input,
                                        ylims=ylims, frame_index=frame_index, ax=ax,
                                        kwargs...)
                     end
                     if n_runs > 1
                         put_legend_above(fig, ax)
                     end

                     nt = minimum(ri.nt for ri ∈ run_info)
                     save_animation(fig, frame_index, nt, outfile)

                     return fig
                 catch e
                     println("$($function_name_str)() failed for $var_name, is=$is. Error was $e")
                     return nothing
                 end
             end

             function $function_name(run_info, var_name; is=1, data=nothing,
                                     input=nothing, frame_index=nothing, ax=nothing,
                                     fig=nothing, outfile=nothing, yscale=nothing,
                                     ylims=nothing, it=nothing, ir=nothing, iz=nothing,
                                     ivperp=nothing, ivpa=nothing, ivzeta=nothing,
                                     ivr=nothing, ivz=nothing, kwargs...)
                 if input === nothing
                     if run_info.dfns
                         input = input_dict_dfns[var_name]
                     else
                         input = input_dict[var_name]
                     end
                 end
                 if isa(input, AbstractDict)
                     input = Dict_to_NamedTuple(input)
                 end
                 if data === nothing
                     dim_slices = get_dimension_slice_indices(:t, $(QuoteNode(dim));
                                                              input=input, it=it, is=is,
                                                              ir=ir, iz=iz, ivperp=ivperp,
                                                              ivpa=ivpa, ivzeta=ivzeta,
                                                              ivr=ivr, ivz=ivz)
                     data = postproc_load_variable(run_info, var_name; dim_slices...)
                 else
                     data = select_slice(data, $(QuoteNode(dim)), :t; input=input, it=it,
                                         is=is, ir=ir, iz=iz, ivperp=ivperp, ivpa=ivpa,
                                         ivzeta=ivzeta, ivr=ivr, ivz=ivz)
                 end
                 if frame_index === nothing
                     ind = Observable(1)
                 else
                     ind = frame_index
                 end
                 if ax === nothing
                     fig, ax = get_1d_ax(xlabel="$($dim_str)",
                                         ylabel=get_variable_symbol(var_name),
                                         yscale=yscale)
                 else
                     fig = nothing
                 end

                 nt = size(data, 2)

                 x = $dim_grid
                 if $idim !== nothing
                     x = x[$idim]
                 end
                 animate_1d(x, data; ax=ax, ylims=ylims, frame_index=ind,
                            label=run_info.run_name, kwargs...)

                 if frame_index === nothing
                     if outfile === nothing
                         error("`outfile` is required for $($function_name_str)")
                     end
                     if fig === nothing
                         error("When `outfile` is passed to save the plot, must either pass both "
                               * "`fig` and `ax` or neither. Only `ax` was passed.")
                     end
                     save_animation(fig, ind, nt, outfile)
                 end

                 return fig
             end
         end)
end

# Generate 2d animation functions for all combinations of dimensions
for (dim1, dim2) ∈ two_dimension_combinations_no_t
    function_name_str = "animate_vs_$(dim2)_$(dim1)"
    function_name = Symbol(function_name_str)
    spaces = " " ^ length(function_name_str)
    dim1_str = String(dim1)
    dim2_str = String(dim2)
    dim1_grid = :( run_info.$dim1.grid )
    dim2_grid = :( run_info.$dim2.grid )
    idim1 = Symbol(:i, dim1)
    idim2 = Symbol(:i, dim2)
    eval(quote
             export $function_name

             """
             function $($function_name_str)(run_info::Tuple, var_name; is=1, data=nothing,
                      $($spaces)input=nothing, outfile=nothing, colorscale=identity,
                      $($spaces)transform=identity, it=nothing, ir=nothing, iz=nothing,
                      $($spaces)ivperp=nothing, ivpa=nothing, ivzeta=nothing, ivr=nothing,
                      $($spaces)ivz=nothing, kwargs...)
             function $($function_name_str)(run_info, var_name; is=1, data=nothing,
                      $($spaces)input=nothing, frame_index=nothing, ax=nothing,
                      $($spaces)fig=nothing, colorbar_place=colorbar_place,
                      $($spaces)title=nothing, outfile=nothing, colorscale=identity,
                      $($spaces)transform=identity, it=nothing, ir=nothing, iz=nothing,
                      $($spaces)ivperp=nothing, ivpa=nothing, ivzeta=nothing, ivr=nothing,
                      $($spaces)ivz=nothing, kwargs...)

             Animate `var_name` from the run(s) represented by `run_info` (as returned by
             [`get_run_info`](@ref))vs $($dim1_str) and $($dim2_str).

             If a Tuple of `run_info` is passed, the animations from each run are
             created in a horizontal row, with each sub-animation having the 'run name' as
             its subtitle.

             `it`, `is`, `ir`, `iz`, `ivperp`, `ivpa`, `ivzeta`, `ivr`, and `ivz` can be
             used to select different indices (for non-plotted dimensions) or range (for
             the plotted dimension) to use.

             `colorscale` can be used to set the scaling function for the colors. Options
             are `identity`, `log`, `log2`, `log10`, `sqrt`, `Makie.logit`,
             `Makie.pseudolog10` and `Makie.Symlog10`. `transform` is a function that is
             applied element-by-element to the data before it is plotted. For example when
             using a log scale on data that may contain some negative values it might be
             useful to pass `transform=abs` (to plot the absolute value) or
             `transform=positive_or_nan` (to ignore any negative or zero values).

             Extra `kwargs` are passed to Makie's `heatmap!() function`.

             When a single `run_info` is passed, an `Axis` can be passed to `ax`. If it
             is, the plot will be created in `ax`. When `ax` is passed, a colorbar will be
             created at `colorbar_place` if a `GridPosition` is passed to
             `colorbar_place`.

             `outfile` is required for animations unless `ax` is passed. The animation
             will be saved to a file named `outfile`.  The suffix determines the file
             type. If both `outfile` and `ax` are passed, then the `Figure` containing
             `ax` must be passed to `fig` to allow the animation to be saved.

             When a single `run_info` is passed, the (sub-)title can be set with the
             `title` argument.

             By default the data for the variable is loaded from the output represented by
             `run_info`. The data can optionally be passed to `data` if you have already
             loaded it.

             Returns the `Figure`, unless `ax` was passed in which case returns `nothing`.

             By default relevant settings are read from the `var_name` section of
             [`input_dict_dfns`](@ref) (if output that has distribution functions is being
             read) or [`input_dict`](@ref) (otherwise). The settings can also be passed as
             an `AbstractDict` or `NamedTuple` via the `input` argument.  Sometimes
             needed, for example if `var_name` is not present in `input_dict` (in which
             case you would have had to create the array to be plotted and pass it to
             `data`).
             """
             function $function_name end

             function $function_name(run_info::Tuple, var_name; is=1, data=nothing,
                                     input=nothing, outfile=nothing, transform=identity,
                                     kwargs...)

                 try
                     if data === nothing
                         data = Tuple(nothing for _ in run_info)
                     end
                     if outfile === nothing
                         error("`outfile` is required for $($function_name_str)")
                     end

                     fig, ax, colorbar_places = get_2d_ax(length(run_info),
                                                          title=get_variable_symbol(var_name))
                     frame_index = Observable(1)

                     for (d, ri, a, cp) ∈ zip(data, run_info, ax, colorbar_places)
                         $function_name(ri, var_name; is=is, data=d, input=input,
                                        transform=transform, frame_index=frame_index,
                                        ax=a, colorbar_place=cp, title=ri.run_name,
                                        kwargs...)
                     end

                     nt = minimum(ri.nt for ri ∈ run_info)
                     save_animation(fig, frame_index, nt, outfile)

                     return fig
                 catch e
                     println("$($function_name_str) failed for $var_name, is=$is. Error was $e")
                     return nothing
                 end
             end

             function $function_name(run_info, var_name; is=1, data=nothing,
                                     input=nothing, frame_index=nothing, ax=nothing,
                                     fig=nothing, colorbar_place=colorbar_place,
                                     title=nothing, outfile=nothing, it=nothing,
                                     ir=nothing, iz=nothing, ivperp=nothing, ivpa=nothing,
                                     ivzeta=nothing, ivr=nothing, ivz=nothing, kwargs...)
                 if input === nothing
                     if run_info.dfns
                         input = input_dict_dfns[var_name]
                     else
                         input = input_dict[var_name]
                     end
                 end
                 if isa(input, AbstractDict)
                     input = Dict_to_NamedTuple(input)
                 end
                 if data === nothing
                     dim_slices = get_dimension_slice_indices(:t, $(QuoteNode(dim1)),
                                                              $(QuoteNode(dim2));
                                                              input=input, it=it, is=is,
                                                              ir=ir, iz=iz, ivperp=ivperp,
                                                              ivpa=ivpa, ivzeta=ivzeta,
                                                              ivr=ivr, ivz=ivz)
                     data = postproc_load_variable(run_info, var_name; dim_slices...)
                 else
                     data = select_slice(data, $(QuoteNode(dim2)), $(QuoteNode(dim1)), :t;
                                         input=input, it=it, is=is, ir=ir, iz=iz,
                                         ivperp=ivperp, ivpa=ivpa, ivzeta=ivzeta, ivr=ivr,
                                         ivz=ivz)
                 end
                 if input === nothing
                     colormap = "reverse_deep"
                 else
                     colormap = input.colormap
                 end
                 if title === nothing
                     title = get_variable_symbol(var_name)
                 end

                 x = $dim2_grid
                 if $idim2 !== nothing
                     x = x[$idim2]
                 end
                 y = $dim1_grid
                 if $idim1 !== nothing
                     y = y[$idim1]
                 end
                 fig = animate_2d(x, y, data; xlabel="$($dim2_str)",
                                  ylabel="$($dim1_str)", title=title,
                                  frame_index=frame_index, ax=ax,
                                  colorbar_place=colorbar_place, colormap=colormap,
                                  kwargs...)

                 if frame_index === nothing
                     if outfile === nothing
                         error("`outfile` is required for $($function_name_str)")
                     end
                     if fig === nothing
                         error("When `outfile` is passed to save the plot, must either pass both "
                               * "`fig` and `ax` or neither. Only `ax` was passed.")
                     end
                     nt = size(data, 3)
                     save_animation(fig, ind, nt, outfile)
                 end

                 return fig
             end
         end)
end

"""
    get_1d_ax(n=nothing; title=nothing, yscale=nothing, kwargs...)

Create a new `Figure` `fig` and `Axis` `ax` intended for 1d plots.

`title` gives an overall title to the `Figure`.

`yscale` can be used to set the scaling function for the y-axis. Options are `identity`,
`log`, `log2`, `log10`, `sqrt`, `Makie.logit`, `Makie.pseudolog10` and `Makie.Symlog10`.

By default creates a single `Axis`, and returns `(fig, ax)`.
If a number of axes `n` is passed, then `ax` is a `Vector{Axis}` of length `n` (even if
`n` is 1). The axes are created in a horizontal row, and the width of the figure is
increased in proportion to `n`.

Extra `kwargs` are passed to the `Axis()` constructor.
"""
function get_1d_ax(n=nothing; title=nothing, yscale=nothing, kwargs...)
    if yscale !== nothing
        kwargs = tuple(kwargs..., :yscale=>yscale)
    end
    if n == nothing
        fig = Figure(title=title)
        ax = Axis(fig[1,1]; kwargs...)
    else
        fig = Figure(resolution=(600*n, 400), title=title)

        if title !== nothing
            title_layout = fig[1,1] = GridLayout()
            Label(title_layout[1,1:2], title)

            plot_layout = fig[2,1] = GridLayout()
        else
            plot_layout = fig[1,1] = GridLayout()
        end

        ax = [Axis(plot_layout[1,i]; kwargs...) for i in 1:n]
    end

    return fig, ax
end

"""
    get_2d_ax(n=nothing; title=nothing, kwargs...)

Create a new `Figure` `fig` and `Axis` `ax` intended for 2d plots.

`title` gives an overall title to the `Figure`.

By default creates a single `Axis`, and returns `(fig, ax, colorbar_place)`, where
`colorbar_place` is a location in the grid layout that can be passed to `Colorbar()`
located immediately to the right of `ax`.
If a number of axes `n` is passed, then `ax` is a `Vector{Axis}` and `colorbar_place` is a
`Vector{GridPosition}` of length `n` (even if `n` is 1). The axes are created in a
horizontal row, and the width of the figure is increased in proportion to `n`.

Extra `kwargs` are passed to the `Axis()` constructor.
"""
function get_2d_ax(n=nothing; title=nothing, kwargs...)
    if n == nothing
        fig = Figure(title=title)
        ax = Axis(fig[1,1]; kwargs...)
        colorbar_place = fig[1,2]
    else
        fig = Figure(resolution=(600*n, 400))

        if title !== nothing
            title_layout = fig[1,1] = GridLayout()
            Label(title_layout[1,1:2], title)

            plot_layout = fig[2,1] = GridLayout()
        else
            plot_layout = fig[1,1] = GridLayout()
        end
        ax = [Axis(plot_layout[1,2*i-1]; kwargs...) for i in 1:n]
        colorbar_place = [plot_layout[1,2*i] for i in 1:n]
    end

    return fig, ax, colorbar_place
end

"""
    plot_1d(xcoord, data; ax=nothing, xlabel=nothing, ylabel=nothing, title=nothing,
            yscale=nothing, transform=identity, kwargs...)

Make a 1d plot of `data` vs `xcoord`.

`xlabel`, `ylabel` and `title` can be passed to set axis labels and title for the
(sub-)plot.

`yscale` can be used to set the scaling function for the y-axis. Options are `identity`,
`log`, `log2`, `log10`, `sqrt`, `Makie.logit`, `Makie.pseudolog10` and `Makie.Symlog10`.
`transform` is a function that is applied element-by-element to the data before it is
plotted. For example when using a log scale on data that may contain some negative values
it might be useful to pass `transform=abs` (to plot the absolute value) or
`transform=positive_or_nan` (to ignore any negative or zero values).

If `ax` is passed, the plot will be added to that existing `Axis`, otherwise a new
`Figure` and `Axis` will be created.

Other `kwargs` are passed to Makie's `lines!()` function.

If `ax` is not passed, returns the `Figure`, otherwise returns the object returned by
`lines!()`.
"""
function plot_1d(xcoord, data; ax=nothing, xlabel=nothing, ylabel=nothing, title=nothing,
                 yscale=nothing, transform=identity, kwargs...)
    if ax === nothing
        fig, ax = get_1d_ax()
    else
        fig = nothing
    end

    if xlabel !== nothing
        ax.xlabel = xlabel
    end
    if ylabel !== nothing
        ax.ylabel = ylabel
    end
    if title !== nothing
        ax.title = title
    end
    if yscale !== nothing
        ax.yscale = yscale
    end

    # Use transform to allow user to do something like data = abs.(data)
    data = transform.(data)

    l = lines!(ax, xcoord, data; kwargs...)

    if fig === nothing
        return l
    else
        return fig
    end
end

"""
    plot_2d(xcoord, ycoord, data; ax=nothing, colorbar_place=nothing, xlabel=nothing,
            ylabel=nothing, title=nothing, colormap="reverse_deep",
            colorscale=nothing, transform=identity, kwargs...)

Make a 2d plot of `data` vs `xcoord` and `ycoord`.

`xlabel`, `ylabel` and `title` can be passed to set axis labels and title for the
(sub-)plot.

`colorscale` can be used to set the scaling function for the colors. Options are
`identity`, `log`, `log2`, `log10`, `sqrt`, `Makie.logit`, `Makie.pseudolog10` and
`Makie.Symlog10`. `transform` is a function that is applied element-by-element to the data
before it is plotted. For example when using a log scale on data that may contain some
negative values it might be useful to pass `transform=abs` (to plot the absolute value) or
`transform=positive_or_nan` (to ignore any negative or zero values).

If `ax` is passed, the plot will be added to that existing `Axis`, otherwise a new
`Figure` and `Axis` will be created.

`colormap` is included explicitly because we do some special handling so that extra Makie
functionality can be specified by a prefix to the `colormap` string, rather than the
standard Makie mechanism of creating a struct that modifies the colormap. For example
`Reverse("deep")` can be passed as `"reverse_deep"`. This is useful so that these extra
colormaps can be specified in an input file, but is not needed for interactive use.

Other `kwargs` are passed to Makie's `heatmap!()` function.

If `ax` is not passed, returns the `Figure`, otherwise returns the object returned by
`heatmap!()`.
"""
function plot_2d(xcoord, ycoord, data; ax=nothing, colorbar_place=nothing, xlabel=nothing,
                 ylabel=nothing, title=nothing, colormap="reverse_deep",
                 colorscale=nothing, transform=identity, kwargs...)
    if ax === nothing
        fig, ax, colorbar_place = get_2d_ax()
    else
        fig = nothing
    end

    if xlabel !== nothing
        ax.xlabel = xlabel
    end
    if ylabel !== nothing
        ax.ylabel = ylabel
    end
    if title !== nothing
        ax.title = title
    end
    colormap = parse_colormap(colormap)
    if colorscale !== nothing
        kwargs = tuple(kwargs..., :colorscale=>colorscale)
    end

    # Use transform to allow user to do something like data = abs.(data)
    data = transform.(data)

    # Convert grid point values to 'cell face' values for heatmap
    xcoord = grid_points_to_faces(xcoord)
    ycoord = grid_points_to_faces(ycoord)

    hm = heatmap!(ax, xcoord, ycoord, data; kwargs...)
    if colorbar_place === nothing
        println("Warning: colorbar_place argument is required to make a color bar")
    else
        Colorbar(colorbar_place, hm)
    end

    if fig === nothing
        return hm
    else
        return fig
    end
end

"""
    animate_1d(xcoord, data; frame_index=nothing, ax=nothing, fig=nothing,
               xlabel=nothing, ylabel=nothing, title=nothing, yscale=nothing,
               transform=identity, outfile=nothing, ylims=nothing, kwargs...)

Make a 1d animation of `data` vs `xcoord`.

`xlabel`, `ylabel` and `title` can be passed to set axis labels and title for the
(sub-)plot.

`ylims` can be passed a Tuple (ymin, ymax) to set the y-axis limits. By default the
minimum and maximum of the data (over all time points) will be used.

`yscale` can be used to set the scaling function for the y-axis. Options are `identity`,
`log`, `log2`, `log10`, `sqrt`, `Makie.logit`, `Makie.pseudolog10` and `Makie.Symlog10`.
`transform` is a function that is applied element-by-element to the data before it is
plotted. For example when using a log scale on data that may contain some negative values
it might be useful to pass `transform=abs` (to plot the absolute value) or
`transform=positive_or_nan` (to ignore any negative or zero values).

If `ax` is passed, the animation will be added to that existing `Axis`, otherwise a new
`Figure` and `Axis` will be created. If `ax` is passed, you should also pass an
`Observable{mk_int}` to `frame_index` so that the data for this animation can be updated
when `frame_index` is changed.

If `outfile` is passed the animation will be saved to a file with that name. The suffix
determines the file type. If `ax` is passed at the same time as `outfile` then the
`Figure` containing `ax` must also be passed (to the `fig` argument) so that the animation
can be saved.

Other `kwargs` are passed to Makie's `lines!()` function.

If `ax` is not passed, returns the `Figure`, otherwise returns the object returned by
`lines!()`.
"""
function animate_1d(xcoord, data; frame_index=nothing, ax=nothing, fig=nothing,
                    xlabel=nothing, ylabel=nothing, title=nothing, yscale=nothing,
                    transform=identity, ylims=nothing, outfile=nothing, kwargs...)

    if frame_index === nothing
        ind = Observable(1)
    else
        ind = frame_index
    end

    if ax === nothing
        fig, ax = get_1d_ax(title=title, xlabel=xlabel, ylabel=ylabel, yscale=yscale)
    end

    # Use transform to allow user to do something like data = abs.(data)
    data = transform.(data)

    if ylims === nothing
        datamin, datamax = NaNMath.extrema(data)
        if ax.limits.val[2] === nothing
            # No limits set yet, need to use minimum and maximum of data over all time,
            # otherwise the automatic axis scaling would use the minimum and maximum of
            # the data at the initial time point.
            ylims!(ax, datamin, datamax)
        else
            # Expand currently set limits to ensure they include the minimum and maxiumum
            # of the data.
            current_ymin, current_ymax = ax.limits.val[2]
            ylims!(ax, min(datamin, current_ymin), max(datamax, current_ymax))
        end
    else
        # User passed ylims explicitly, so set those.
        ylims!(ax, ylims)
    end

    line_data = @lift(@view data[:,$ind])
    lines!(ax, xcoord, line_data; kwargs...)

    if outfile !== nothing
        if fig === nothing
            error("When `outfile` is passed to save the animation, must either pass both "
                  * "`fig` and `ax` or neither. Only `ax` was passed.")
        end
        nt = size(data, 2)
        save_animation(fig, ind, nt, outfile)
    end
end

"""
    animate_2d(xcoord, ycoord, data; frame_index=nothing, ax=nothing, fig=nothing,
               colorbar_place=nothing, xlabel=nothing, ylabel=nothing, title=nothing,
               outfile=nothing, colormap="reverse_deep", colorscale=nothing,
               transform=identity, kwargs...)

Make a 2d animation of `data` vs `xcoord` and `ycoord`.

`xlabel`, `ylabel` and `title` can be passed to set axis labels and title for the
(sub-)plot.

`colorscale` can be used to set the scaling function for the colors. Options are
`identity`, `log`, `log2`, `log10`, `sqrt`, `Makie.logit`, `Makie.pseudolog10` and
`Makie.Symlog10`. `transform` is a function that is applied element-by-element to the data
before it is plotted. For example when using a log scale on data that may contain some
negative values it might be useful to pass `transform=abs` (to plot the absolute value) or
`transform=positive_or_nan` (to ignore any negative or zero values).

If `ax` is passed, the animation will be added to that existing `Axis`, otherwise a new
`Figure` and `Axis` will be created. If `ax` is passed, you should also pass an
`Observable{mk_int}` to `frame_index` so that the data for this animation can be updated
when `frame_index` is changed.

If `outfile` is passed the animation will be saved to a file with that name. The suffix
determines the file type. If `ax` is passed at the same time as `outfile` then the
`Figure` containing `ax` must also be passed (to the `fig` argument) so that the animation
can be saved.

`colormap` is included explicitly because we do some special handling so that extra Makie
functionality can be specified by a prefix to the `colormap` string, rather than the
standard Makie mechanism of creating a struct that modifies the colormap. For example
`Reverse("deep")` can be passed as `"reverse_deep"`. This is useful so that these extra
colormaps can be specified in an input file, but is not needed for interactive use.

Other `kwargs` are passed to Makie's `heatmap!()` function.

If `ax` is not passed, returns the `Figure`, otherwise returns the object returned by
`heatmap!()`.
"""
function animate_2d(xcoord, ycoord, data; frame_index=nothing, ax=nothing, fig=nothing,
                    colorbar_place=nothing, xlabel=nothing, ylabel=nothing, title=nothing,
                    outfile=nothing, colormap="reverse_deep", colorscale=nothing,
                    transform=identity, kwargs...)
    colormap = parse_colormap(colormap)

    if ax === nothing
        fig, ax, colorbar_place = get_2d_ax()
    end
    if frame_index === nothing
        ind = Observable(1)
    else
        ind = frame_index
    end
    if xlabel !== nothing
        ax.xlabel = xlabel
    end
    if ylabel !== nothing
        ax.ylabel = ylabel
    end
    if title !== nothing
        ax.title = title
    end
    if colorscale !== nothing
        kwargs = tuple(kwargs..., :colorscale=>colorscale)
    end

    # Use transform to allow user to do something like data = abs.(data)
    data = transform.(data)

    xcoord = grid_points_to_faces(xcoord)
    ycoord = grid_points_to_faces(ycoord)
    heatmap_data = @lift(@view data[:,:,$ind])
    hm = heatmap!(ax, xcoord, ycoord, heatmap_data; colormap=colormap, kwargs...)
    Colorbar(colorbar_place, hm)

    if outfile !== nothing
        if fig === nothing
            error("When `outfile` is passed to save the animation, must either pass both "
                  * "`fig` and `ax` or neither. Only `ax` was passed.")
        end
        nt = size(data, 3)
        save_animation(fig, ind, nt, outfile)
    end

    return fig
end

"""
    save_animation(fig, frame_index, nt, outfile)

Animate `fig` and save the result in `outfile`.

`frame_index` is the `Observable{mk_int}` that updates the data used to make `fig` to a
new time point. `nt` is the total number of time points to create.

The suffix of `outfile` determines the file type.
"""
function save_animation(fig, frame_index, nt, outfile)
    record(fig, outfile, 1:nt, framerate=5) do it
        frame_index[] = it
    end
    return nothing
end

"""
   put_legend_above(fig, ax; kwargs...)

Add a legend corresponding to the plot in `ax` to `fig` on the left of a new row at the
top of the figure layout.

Additional `kwargs` are passed to the `Legend()` constructor.
"""
function put_legend_above(fig, ax; kwargs...)
    return Legend(fig[0,1], ax; tellheight=true, tellwidth=false, kwargs...)
end

"""
   put_legend_below(fig, ax; kwargs...)

Add a legend corresponding to the plot in `ax` to `fig` on the left of a new row at the
bottom of the figure layout.

Additional `kwargs` are passed to the `Legend()` constructor.
"""
function put_legend_below(fig, ax; kwargs...)
    return Legend(fig[end+1,1], ax; tellheight=true, tellwidth=false, kwargs...)
end

"""
   put_legend_left(fig, ax; kwargs...)

Add a legend corresponding to the plot in `ax` to `fig` on the bottom of a new column at
the left of the figure layout.

Additional `kwargs` are passed to the `Legend()` constructor.
"""
function put_legend_left(fig, ax; kwargs...)
    return Legend(fig[end,0], ax; kwargs...)
end

"""
   put_legend_right(fig, ax; kwargs...)

Add a legend corresponding to the plot in `ax` to `fig` on the bottom of a new column at
the right of the figure layout.

Additional `kwargs` are passed to the `Legend()` constructor.
"""
function put_legend_right(fig, ax; kwargs...)
    return Legend(fig[end,end+1], ax; kwargs...)
end

"""
    select_slice(variable::AbstractArray, dims::Symbol...; input=nothing, it=nothing,
                 is=1, ir=nothing, iz=nothing, ivperp=nothing, ivpa=nothing,
                 ivzeta=nothing, ivr=nothing, ivz=nothing)

Returns a slice of `variable` that includes only the dimensions given in `dims...`, e.g.
```
select_slice(variable, :t, :r)
```
to get a two dimensional slice with t- and r-dimensions.

Any other dimensions present in `variable` have a single point selected. By default this
point is set by the options in `input` (which must be a NamedTuple) (or the final point
for time or the size of the dimension divided by 3 if `input` is not given). These
defaults can be overridden using the keyword arguments `it`, `is`, `ir`, `iz`, `ivperp`,
`ivpa`, `ivzeta`, `ivr`, `ivz`. Ranges can also be passed to these keyword arguments for
the 'kept dimensions' in `dims` to select a subset of those dimensions.

This function only recognises what the dimensions of `variable` are by the number of
dimensions in the array. It assumes that either the variable has already been sliced to
the correct dimensions (if `ndims(variable) == length(dims)` it just returns `variable`)
or that `variable` has the full number of dimensions it could have (i.e. 'field' variables
have 3 dimensions, 'moment' variables 4, 'ion distribution function' variables 6 and
'neutral distribution function' variables 7).
"""
function select_slice end

function select_slice(variable::AbstractArray{T,1}, dims::Symbol...; input=nothing,
                      is=nothing, kwargs...) where T
    if length(dims) > 1
        error("Tried to get a slice of 1d variable with dimensions $dims")
    elseif length(dims) < 1
        error("1d variable must have already been sliced, so don't know what the dimensions are")
    else
        # Array is not a standard shape, so assume it is already sliced to the right 2
        # dimensions
        return variable
    end
end

function select_slice(variable::AbstractArray{T,2}, dims::Symbol...; input=nothing,
                      is=nothing, kwargs...) where T
    if length(dims) > 2
        error("Tried to get a slice of 2d variable with dimensions $dims")
    elseif length(dims) < 2
        error("2d variable must have already been sliced, so don't know what the dimensions are")
    else
        # Array is not a standard shape, so assume it is already sliced to the right 2
        # dimensions
        return variable
    end
end

function select_slice(variable::AbstractArray{T,3}, dims::Symbol...; input=nothing,
                      it=nothing, is=nothing, ir=nothing, iz=nothing, kwargs...) where T
    # Array is (z,r,t)

    if length(dims) > 3
        error("Tried to get a slice of 3d variable with dimensions $dims")
    end

    if it !== nothing
        it0 = it
    elseif input === nothing || :it0 ∉ input
        it0 = size(variable, 3)
    else
        it0 = input.it0
    end
    if ir !== nothing
        ir0 = ir
    elseif input === nothing || :ir0 ∉ input
        ir0 = max(size(variable, 2) ÷ 3, 1)
    else
        ir0 = input.ir0
    end
    if iz !== nothing
        iz0 = iz
    elseif input === nothing || :iz0 ∉ input
        iz0 = max(size(variable, 1) ÷ 3, 1)
    else
        iz0 = input.iz0
    end

    slice = variable
    if :t ∉ dims || it !== nothing
        slice = selectdim(slice, 3, it0)
    end
    if :r ∉ dims || ir !== nothing
        slice = selectdim(slice, 2, ir0)
    end
    if :z ∉ dims || iz !== nothing
        slice = selectdim(slice, 1, iz0)
    end

    return slice
end

function select_slice(variable::AbstractArray{T,4}, dims::Symbol...; input=nothing,
                      it=nothing, is=1, ir=nothing, iz=nothing, kwargs...) where T
    # Array is (z,r,species,t)

    if it !== nothing
        it0 = it
    elseif input === nothing || :it0 ∉ input
        it0 = size(variable, 4)
    else
        it0 = input.it0
    end
    if ir !== nothing
        ir0 = ir
    elseif input === nothing || :ir0 ∉ input
        ir0 = max(size(variable, 2) ÷ 3, 1)
    else
        ir0 = input.ir0
    end
    if iz !== nothing
        iz0 = iz
    elseif input === nothing || :iz0 ∉ input
        iz0 = max(size(variable, 1) ÷ 3, 1)
    else
        iz0 = input.iz0
    end

    slice = variable
    if :t ∉ dims || it !== nothing
        slice = selectdim(slice, 4, it0)
    end
    slice = selectdim(slice, 3, is)
    if :r ∉ dims || ir !== nothing
        slice = selectdim(slice, 2, ir0)
    end
    if :z ∉ dims || iz !== nothing
        slice = selectdim(slice, 1, iz0)
    end

    return slice
end

function select_slice(variable::AbstractArray{T,6}, dims::Symbol...; input=nothing,
                      it=nothing, is=1, ir=nothing, iz=nothing, ivperp=nothing,
                      ivpa=nothing, kwargs...) where T
    # Array is (z,r,species,t)

    if it !== nothing
        it0 = it
    elseif input === nothing || :it0 ∉ input
        it0 = size(variable, 6)
    else
        it0 = input.it0
    end
    if ir !== nothing
        ir0 = ir
    elseif input === nothing || :ir0 ∉ input
        ir0 = max(size(variable, 4) ÷ 3, 1)
    else
        ir0 = input.ir0
    end
    if iz !== nothing
        iz0 = iz
    elseif input === nothing || :iz0 ∉ input
        iz0 = max(size(variable, 3) ÷ 3, 1)
    else
        iz0 = input.iz0
    end
    if ivpa !== nothing
        ivpa0 = ivpa
    elseif input === nothing || :ivpa0 ∉ input
        ivpa0 = max(size(variable, 2) ÷ 3, 1)
    else
        ivpa0 = input.ivpa0
    end
    if ivperp !== nothing
        ivperp0 = ivperp
    elseif input === nothing || :ivperp0 ∉ input
        ivperp0 = max(size(variable, 1) ÷ 3, 1)
    else
        ivperp0 = input.ivperp0
    end

    slice = variable
    if :t ∉ dims || it !== nothing
        slice = selectdim(slice, 6, it0)
    end
    slice = selectdim(slice, 5, is)
    if :r ∉ dims || ir !== nothing
        slice = selectdim(slice, 4, ir0)
    end
    if :z ∉ dims || iz !== nothing
        slice = selectdim(slice, 3, iz0)
    end
    if :vperp ∉ dims || ivperp !== nothing
        slice = selectdim(slice, 2, ivperp0)
    end
    if :vpa ∉ dims || ivpa !== nothing
        slice = selectdim(slice, 1, ivpa0)
    end

    return slice
end

function select_slice(variable::AbstractArray{T,7}, dims::Symbol...; input=nothing,
                      it=nothing, is=1, ir=nothing, iz=nothing, ivzeta=nothing,
                      ivr=nothing, ivz=nothing, kwargs...) where T
    # Array is (z,r,species,t)

    if it !== nothing
        it0 = it
    elseif input === nothing || :it0 ∉ input
        it0 = size(variable, 7)
    else
        it0 = input.it0
    end
    if ir !== nothing
        ir0 = ir
    elseif input === nothing || :ir0 ∉ input
        ir0 = max(size(variable, 5) ÷ 3, 1)
    else
        ir0 = input.ir0
    end
    if iz !== nothing
        iz0 = iz
    elseif input === nothing || :iz0 ∉ input
        iz0 = max(size(variable, 4) ÷ 3, 1)
    else
        iz0 = input.iz0
    end
    if ivzeta !== nothing
        ivzeta0 = ivzeta
    elseif input === nothing || :ivzeta0 ∉ input
        ivzeta0 = max(size(variable, 3) ÷ 3, 1)
    else
        ivzeta0 = input.ivzeta0
    end
    if ivr !== nothing
        ivr0 = ivr
    elseif input === nothing || :ivr0 ∉ input
        ivr0 = max(size(variable, 2) ÷ 3, 1)
    else
        ivr0 = input.ivr0
    end
    if ivz !== nothing
        ivz0 = ivz
    elseif input === nothing || :ivz0 ∉ input
        ivz0 = max(size(variable, 1) ÷ 3, 1)
    else
        ivz0 = input.ivz0
    end

    slice = variable
    if :t ∉ dims || it !== nothing
        slice = selectdim(slice, 7, it0)
    end
    slice = selectdim(slice, 6, is)
    if :r ∉ dims || ir !== nothing
        slice = selectdim(slice, 5, ir0)
    end
    if :z ∉ dims || iz !== nothing
        slice = selectdim(slice, 4, iz0)
    end
    if :vzeta ∉ dims || ivzeta !== nothing
        slice = selectdim(slice, 3, ivzeta0)
    end
    if :vr ∉ dims || ivr !== nothing
        slice = selectdim(slice, 2, ivr0)
    end
    if :vz ∉ dims || ivz !== nothing
        slice = selectdim(slice, 1, ivz0)
    end

    return slice
end

"""
get_dimension_slice_indices(keep_dims...; input, it=nothing, is=nothing,
                            ir=nothing, iz=nothing, ivperp=nothing, ivpa=nothing,
                            ivzeta=nothing, ivr=nothing, ivz=nothing)

Get indices for dimensions to slice

The indices are taken from `input`, unless they are passed as keyword arguments

The dimensions in `keep_dims` are not given a slice (those are the dimensions we want in
the variable after slicing).
"""
function get_dimension_slice_indices(keep_dims...; input, it=nothing, is=nothing,
                                     ir=nothing, iz=nothing, ivperp=nothing, ivpa=nothing,
                                     ivzeta=nothing, ivr=nothing, ivz=nothing)
    if isa(input, AbstractDict)
        input = Dict_to_NamedTuple(input)
    end
    return (:it=>(it === nothing ? (:t ∈ keep_dims ? nothing : input.it0) : it),
            :is=>(is === nothing ? (:s ∈ keep_dims ? nothing : input.is0) : is),
            :ir=>(ir === nothing ? (:r ∈ keep_dims ? nothing : input.ir0) : ir),
            :iz=>(iz === nothing ? (:z ∈ keep_dims ? nothing : input.iz0) : iz),
            :ivperp=>(ivperp === nothing ? (:vperp ∈ keep_dims ? nothing : input.ivperp0) : ivperp),
            :ivpa=>(ivpa === nothing ? (:vpa ∈ keep_dims ? nothing : input.ivpa0) : ivpa),
            :ivzeta=>(ivzeta === nothing ? (:vzeta ∈ keep_dims ? nothing : input.ivzeta0) : ivzeta),
            :ivr=>(ivr === nothing ? (:vr ∈ keep_dims ? nothing : input.ivr0) : ivr),
            :ivz=>(ivz === nothing ? (:vz ∈ keep_dims ? nothing : input.ivz0) : ivz))
end

"""
    grid_points_to_faces(coord::AbstractVector)

Turn grid points in `coord` into 'cell faces'.

Returns `faces`, which has a length one greater than `coord`. The first and last values of
`faces` are the first and last values of `coord`. The intermediate values are the mid
points between grid points.
"""
function grid_points_to_faces(coord::AbstractVector)
    n = length(coord)
    faces = allocate_float(n+1)
    faces[1] = coord[1]
    for i ∈ 2:n
        faces[i] = 0.5*(coord[i-1] + coord[i])
    end
    faces[n+1] = coord[n]

    return faces
end

"""
    get_variable_symbol(variable_name)

Get a symbol corresponding to a `variable_name`

For example `get_variable_symbol("phi")` returns `"ϕ"`.

If the symbol has not been defined, just return `variable_name`.
"""
function get_variable_symbol(variable_name)
    symbols_for_variables = Dict("phi"=>"ϕ", "Er"=>"Er", "Ez"=>"Ez", "density"=>"n",
                                 "parallel_flow"=>"u∥", "parallel_pressure"=>"p∥",
                                 "parallel_heat_flux"=>"q∥", "thermal_speed"=>"vth",
                                 "temperature"=>"T", "density_neutral"=>"nn",
                                 "uzeta_neutral"=>"unζ", "ur_neutral"=>"unr",
                                 "uz_neutral"=>"unz", "pzeta_neutral"=>"pnζ",
                                 "pr_neutral"=>"pnr", "pz_neutral"=>"pnz",
                                 "qzeta_neutral"=>"qnζ", "qr_neutral"=>"qnr",
                                 "qz_neutral"=>"qnz", "thermal_speed_neutral"=>"vnth",
                                 "temperature_neutral"=>"Tn")

    return get(symbols_for_variables, variable_name, variable_name)
end

"""
    parse_colormap(colormap)

Parse a `colormap` option

Allows us to have a string option which can be set in the input file and still use
Reverse, etc. conveniently.
"""
function parse_colormap(colormap)
    if colormap === nothing
        return colormap
    elseif startswith(colormap, "reverse_")
        # Use split to remove the "reverse_" prefix
        return Reverse(String(split(colormap, "reverse_", keepempty=false)[1]))
    else
        return colormap
    end
end

# Utility functions
###################
#
# These are more-or-less generic, but only used in this module for now, so keep them here.

"""
    clear_Dict!(d::AbstractDict)

Remove all entries from an AbstractDict, leaving it empty
"""
function clear_Dict!(d::AbstractDict)
    # This is one way to clear all entries from a dict, by using a filter which is false
    # for every entry
    if !isempty(d)
        filter!(x->false, d)
    end

    return d
end

"""
    convert_to_OrderedDicts!(d::AbstractDict)

Recursively convert an AbstractDict to OrderedDict.

Any nested AbstractDicts are also converted to OrderedDict.
"""
function convert_to_OrderedDicts!(d::AbstractDict)
    for (k, v) ∈ d
        if isa(v, AbstractDict)
            d[k] = convert_to_OrderedDicts!(v)
        end
    end
    return OrderedDict(d)
end

"""
    positive_or_nan(x; epsilon=0)

If the argument `x` is zero or negative, replace it with NaN, otherwise return `x`.

`epsilon` can be passed if the number should be forced to be above some value (typically
we would assume epsilon is small and positive, but nothing about this function forces it
to be).
"""
function positive_or_nan(x; epsilon=0)
    return x > epsilon ? x : NaN
end

end

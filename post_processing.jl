# add the current directory to the path where the code looks for external modules
push!(LOAD_PATH, ".")

# packages
using NCDatasets
using Plots
using LsqFit
# modules
using post_processing_input: pp
using quadrature: composite_simpson_weights
using array_allocation: allocate_float
using file_io: open_output_file

function analyze_and_plot_data()
    # get the run_name from the command-line
    run_name = ARGS[1]

    # create the netcdf filename from the given run_name
    filename = string(run_name, ".cdf")

    print("Opening ", filename, " to read NetCDF data...")
    # open the netcdf file with given filename for reading
    fid = NCDataset(filename,"r")
    println("done.")

    print("Loading coordinate data...")
    # define a handle for the z coordinate
    cdfvar = fid["z"]
    # get the number of z grid points
    nz = length(cdfvar)
    # load the data for z
    z = cdfvar.var[:]

    # define a handle for the vpa coordinate
    cdfvar = fid["vpa"]
    # get the number of vpa grid points
    nvpa = length(cdfvar)
    # load the data for vpa
    vpa = cdfvar.var[:]

    # define a handle for the time coordinate
    cdfvar = fid["time"]
    # get the number of time grid points
    ntime = length(cdfvar)
    # load the data for time
    time = cdfvar.var[:]
    println("done.")

    print("Initializing the post-processing input options...")
    # nwrite_movie is the stride used when making animations
    nwrite_movie = pp.nwrite_movie
    # itime_min is the minimum time index at which to start animations
    if pp.itime_min > 0
        itime_min = pp.itime_min
    else
        itime_min = 1
    end
    # itime_max is the final time index at which to end animations
    # if itime_max < 0, the value used will be the total number of time slices
    if pp.itime_max > 0
        itime_max = pp.itime_max
    else
        itime_max = ntime
    end
    # iz0 is the iz index used when plotting data at a single z location
    # by default, it will be set to cld(nz,2) unless a non-negative value provided
    if pp.iz0 > 0
        iz0 = pp.iz0
    else
        iz0 = cld(nz,2)
    end
    # ivpa0 is the iz index used when plotting data at a single vpa location
    # by default, it will be set to cld(nvpa,2) unless a non-negative value provided
    if pp.ivpa0 > 0
        ivpa0 = pp.ivpa0
    else
        ivpa0 = cld(nvpa,2)
    end
    println("done.")

    print("Loading fields data...")
    # define a handle for the electrostatic potential
    cdfvar = fid["phi"]
    # load the electrostatic potential data
    phi = cdfvar.var[:,:]
    println("done.")

    print("Analyzing fields data...")
    # compute the z integration weights needed to do field line averages
    z_wgts = composite_simpson_weights(z)
    # Lz = z box length
    Lz = z[end]-z[1]
    phi_fldline_avg = allocate_float(ntime)
    for i ∈ 1:ntime
        phi_fldline_avg[i] = field_line_average(view(phi,:,i), z_wgts, Lz)
    end
    # delta_phi = phi - <phi> is the fluctuating phi
    delta_phi = allocate_float(nz,ntime)
    for iz ∈ 1:nz
        delta_phi[iz,:] .= phi[iz,:] - phi_fldline_avg
    end
    println("done.")

    if pp.calculate_frequencies
        println("Calculating the frequency and damping/growth rate...")
        # shifted_time = t - t0
        shifted_time = allocate_float(ntime)
        @. shifted_time = time - time[itime_min]
        # assume phi(z0,t) = A*exp(growth_rate*t)*cos(omega*t - φ)
        # and fit phi(z0,t)/phi(z0,t0), which eliminates the constant A pre-factor
        @views growth_rate, frequency, phase =
            fit_phi0_vs_time(delta_phi[iz0,itime_min:itime_max], shifted_time[itime_min:itime_max])
        io = open_output_file(run_name, "frequency_fit.txt")
        println(io, "growth_rate: ", growth_rate, "  frequency: ", frequency, "  phase: ", phase)
        close(io)
        println("done.")
    end

    println("Plotting fields data...")
    phimin = minimum(phi)
    phimax = maximum(phi)
    if pp.plot_phi0_vs_t
        # plot the time trace of phi(z=z0)
        #plot(time, log.(phi[i,:]), yscale = :log10)
        @views plot(time, phi[iz0,:])
        outfile = string(run_name, "_phi0_vs_t.pdf")
        savefig(outfile)
        # plot the time trace of phi(z=z0)-phi_fldline_avg
        @views plot(time, abs.(delta_phi[iz0,:]), xlabel="t*Lz/vti", ylabel="δϕ", yaxis=:log)
        if pp.calculate_frequencies
            plot!(time, abs.(delta_phi[iz0,itime_min]/cos(phase) * exp.(growth_rate*shifted_time)
                .* cos.(frequency*shifted_time .+ phase)))
        end
        outfile = string(run_name, "_delta_phi0_vs_t.pdf")
        savefig(outfile)
    end
    if pp.plot_phi_vs_z_t
        # make a heatmap plot of ϕ(z,t)
        heatmap(time, z, phi, xlabel="time", ylabel="z", title="ϕ", c = :deep)
        outfile = string(run_name, "_phi_vs_z_t.pdf")
        savefig(outfile)
    end
    if pp.animate_phi_vs_z
        # make a gif animation of ϕ(z) at different times
        anim = @animate for i ∈ itime_min:nwrite_movie:itime_max
            @views plot(z, phi[:,i], xlabel="z", ylabel="ϕ", ylims = (phimin,phimax))
        end
        outfile = string(run_name, "_phi_vs_z.gif")
        gif(anim, outfile, fps=5)
    end
    println("done.")

    print("Loading velocity moments data...")
    # define a handle for the ion density
    cdfvar = fid["density"]
    # load the ion density data
    ion_density = cdfvar.var[:,:]
    println("done.")

    print("Analyzing velocity moments data...")
    ion_density_fldline_avg = allocate_float(ntime)
    for i ∈ 1:ntime
        ion_density_fldline_avg[i] = field_line_average(view(ion_density,:,i), z_wgts, Lz)
    end
    # delta_ion_density = n_i - <n_i> is the fluctuating density
    delta_ion_density = allocate_float(nz,ntime)
    for iz ∈ 1:nz
        delta_ion_density[iz,:] .= ion_density[iz,:] - ion_density_fldline_avg
    end
    println("done.")

    println("Plotting velocity moments data...")
    ion_dens_min = minimum(ion_density)
    ion_dens_max = maximum(ion_density)
    if pp.plot_dens0_vs_t
        # plot the time trace of n_i(z=z0)
        @views plot(time, ion_density[iz0,:])
        outfile = string(run_name, "_dens0_vs_t.pdf")
        savefig(outfile)
        # plot the time trace of n_i(z=z0)-ion_density_fldline_avg
        @views plot(time, abs.(delta_ion_density[iz0,:]), yaxis=:log)
        outfile = string(run_name, "_delta_dens0_vs_t.pdf")
        savefig(outfile)
        # plot the time trace of ion_density_fldline_avg
        @views plot(time, ion_density_fldline_avg, xlabel="time", ylabel="<nᵢ/Nₑ>", ylims=(ion_dens_min,ion_dens_max))
        outfile = string(run_name, "_fldline_avg_dens_vs_t.pdf")
        savefig(outfile)
    end
    if pp.plot_dens_vs_z_t
        # make a heatmap plot of n_i(z,t)
        heatmap(time, z, ion_density, xlabel="time", ylabel="z", title="nᵢ/Nₑ", c = :deep)
        outfile = string(run_name, "_dens_vs_z_t.pdf")
        savefig(outfile)
    end
    if pp.animate_dens_vs_z
        # make a gif animation of ϕ(z) at different times
        anim = @animate for i ∈ itime_min:nwrite_movie:itime_max
            @views plot(z, ion_density[:,i], xlabel="z", ylabel="nᵢ/Nₑ", ylims = (ion_dens_min,ion_dens_max))
        end
        outfile = string(run_name, "_dens_vs_z.gif")
        gif(anim, outfile, fps=5)
    end
    println("done.")

    print("Loading distribution function data...")
    # define a handle for the distribution function
    cdfvar = fid["f"]
    # load the distribution function data
    ff = cdfvar.var[:,:,:]
    println("done.")

    println("Plotting distribution function data...")
    cmlog(cmlin::ColorGradient) = RGB[cmlin[x] for x=LinRange(0,1,30)]
    logdeep = cgrad(:deep, scale=:log) |> cmlog
    fmin = minimum(ff)
    fmax = maximum(ff)
    if pp.animate_f_vs_z_vpa
        # make a gif animation of f(vpa,z,t)
        anim = @animate for i ∈ itime_min:nwrite_movie:itime_max
            #heatmap(vpa, z, log.(abs.(ff[:,:,i])), xlabel="vpa", ylabel="z", clims = (fmin,fmax), c = :deep)
            @views heatmap(vpa, z, log.(abs.(ff[:,:,i])), xlabel="vpa", ylabel="z", fillcolor = logdeep)
        end
        outfile = string(run_name, "_f_vs_z_vpa.gif")
        gif(anim, outfile, fps=5)
    end
    if pp.animate_f_vs_z_vpa0
        # make a gif animation of f(vpa0,z,t)
        anim = @animate for i ∈ itime_min:nwrite_movie:itime_max
            @views plot(z, ff[:,ivpa0,i], ylims = (fmin,fmax))
        end
        outfile = string(run_name, "_f_vs_z.gif")
        gif(anim, outfile, fps=5)
    end
    if pp.animate_f_vs_z0_vpa
        # make a gif animation of f(vpa,z0,t)
        anim = @animate for i ∈ itime_min:nwrite_movie:itime_max
            @views plot(vpa, ff[iz0,:,i], ylims = (fmin,fmax))
        end
        outfile = string(run_name, "_f_vs_vpa.gif")
        gif(anim, outfile, fps=5)
    end
    println("done.")

    close(fid)

end

function field_line_average(fld, wgts, L)
    n = length(fld)
    total = 0.0
    for i ∈ 1:n
        total += wgts[i]*fld[i]
    end
    return total/L
end

function fit_phi0_vs_time(phi0, tmod)
    # the model we are fitting to the data is given by the function 'model':
    # assume phi(z0,t) = exp(γt)cos(ωt-φ) so that
    # phi(z0,t)/phi(z0,t0) = exp((t-t₀)γ)*cos((t-t₀)*ω + phase)/cos(phase),
    # where tmod = t-t0 and phase = ωt₀-φ
    @. model(t, p) = exp(p[1]*t) * cos(p[2]*t + p[3]) / cos(p[3])
    model_params = allocate_float(3)
    model_params[1] = -0.1
    model_params[2] = 1.0
    model_params[3] = 0.0
    @views fit = curve_fit(model, tmod, phi0/phi0[1], model_params)
    return fit.param[1], fit.param[2], fit.param[3]
end

analyze_and_plot_data()

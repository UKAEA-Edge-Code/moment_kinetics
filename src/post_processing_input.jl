"""
"""
module post_processing_input

export load_post_processing_options
export pp

using ..type_definitions: mk_int
using ..input_structs: pp_input

# if calculate_frequencies = true, calculate and print the frequency and growth/decay
# rate of phi, using values at iz = iz0
const calculate_frequencies = false
# if plot_phi0_vs_t = true, create plot of phi(z0) vs time
const plot_phi0_vs_t = true
# if plot_phi_vs_z_t = true, create heatmap of phi vs z and time
const plot_phi_vs_z_t = true
# if animate_phi_vs_z = true, create animation of phi(z) at different time slices
const animate_phi_vs_z = true
# if plot_dens0_vs_t = true, create plots of species density(z0) vs time
const plot_dens0_vs_t = true
# if plot_upar0_vs_t = true, create plots of species upar(z0) vs time
const plot_upar0_vs_t = false
# if plot_ppar0_vs_t = true, create plots of species ppar(z0) vs time
const plot_ppar0_vs_t = false
# if plot_qpar0_vs_t = true, create plots of species qpar(z0) vs time
const plot_qpar0_vs_t = false
# if plot_dens_vs_z_t = true, create heatmap of species density vs z and time
const plot_dens_vs_z_t = true
# if plot_upar_vs_z_t = true, create heatmap of species parallel flow vs z and time
const plot_upar_vs_z_t = false
# if plot_ppar_vs_z_t = true, create heatmap of species parallel pressure vs z and time
const plot_ppar_vs_z_t = false
# if plot_qpar_vs_z_t = true, create heatmap of species parallel heat flux vs z and time
const plot_qpar_vs_z_t = false
# if animate_dens_vs_z = true, create animation of species density(z) at different time slices
const animate_dens_vs_z =  false #ttrue
# if animate_upar_vs_z = true, create animation of species parallel flow(z) at different time slices
const animate_upar_vs_z = false
# if animate_f_vs_vpa_z = true, create animation of f(vpa,z) at different time slices
const animate_f_vs_vpa_z =  false #ttrue
# if animate_deltaf_vs_vpa_z = true, create animation of δf(vpa,z) at different time slices
const animate_deltaf_vs_vpa_z = false
# if animate_f_vs_vpa_z0 = true, create animation of f(vpa0,z) at different time slices
const animate_f_vs_vpa_z0 = false
# if animate_deltaf_vs_vpa_z0 = true, create animation of δf(vpa0,z) at different time slices
const animate_deltaf_vs_vpa_z0 = false
# if animate_f_vs_z0_vpa = true, create animation of f(vpa,z0) at different time slices
const animate_f_vs_z0_vpa =  false #ttrue
# if animate_deltaf_vs_z0_vpa = true, create animation of δf(vpa,z0) at different time slices
const animate_deltaf_vs_vpa_z0 = false
# if animate_f_vs_vpa_r = true, create animation of f(vpa,r) at different time slices
const animate_f_vs_vpa_r =  false #ttrue
# if animate_f_vs_vperp_z = true, create animation of f(vperp,z) at different time slices
const animate_f_vs_vperp_z =  false #ttrue
# if animate_f_vs_vperp_r = true, create animation of f(vperp,r) at different time slices
const animate_f_vs_vperp_r = false
# if animate_f_vs_vperp_vpa = true, create animation of f(vperp,vpa) at different time slices
const animate_f_vs_vperp_vpa = false
# if animate_f_vs_r_z = true, create animation of f(r,z) at different time slices
const animate_f_vs_r_z =  false #ttrue
# if animate_f_vs_vz_z = true, create animation of f(vz,z) at different time slices
const animate_f_vs_vz_z = false
# if animate_f_vs_vr_r = true, create animation of f(vr,r) at different time slices
const animate_f_vs_vr_r = false
# animations will use one in every nwrite_movie data slices
const animate_Er_vs_r_z =  false #ttrue
# if animate_Er_vs_r_z = true, create animation of Er(r,z) at different time slices
const animate_Ez_vs_r_z = false #true
# if animate_Ez_vs_r_z = true, create animation of Ez(r,z) at different time slices
const animate_phi_vs_r_z = false #true
# if animate_phi_vs_r_z = true, create animation of phi(r,z) at different time slices
const nwrite_movie = 1
# itime_min is the minimum time index at which to start animations
const itime_min = -1
# itime_max is the final time index at which to end animations
# if itime_max < 0, the value used will be the total number of time slices
const itime_max = -1
# ivpa0 is the ivpa index used when plotting data at a single vpa location
# by default, it will be set to cld(nvpa,3) unless a non-negative value provided here
const ivpa0 = -1
# ivperp0 is the ivperp index used when plotting data at a single vperp location
# by default, it will be set to cld(nvperp,3) unless a non-negative value provided here
const ivperp0 = -1
# iz0 is the iz index used when plotting data at a single z location
# by default, it will be set to cld(nz,3) unless a non-negative value provided here
const iz0 = 0
# ir0 is the ir index used when plotting data at a single r location
# by default, it will be set to cld(nr,3) unless a non-negative value provided here
const ir0 = -1
# ivz0 is the ivz index used when plotting data at a single vz location
# by default, it will be set to cld(nvz,3) unless a non-negative value provided here
const ivz0 = -1
# ivr0 is the ivr index used when plotting data at a single vr location
# by default, it will be set to cld(nvr,3) unless a non-negative value provided here
const ivr0 = -1
# ivzeta0 is the ivzeta index used when plotting data at a single vzeta location
# by default, it will be set to cld(nvzeta,3) unless a non-negative value provided here
const ivzeta0 = -1

pp = pp_input(calculate_frequencies, plot_phi0_vs_t, plot_phi_vs_z_t,
    animate_phi_vs_z, plot_dens0_vs_t, plot_upar0_vs_t, plot_ppar0_vs_t, plot_qpar0_vs_t,
    plot_dens_vs_z_t, plot_upar_vs_z_t, plot_ppar_vs_z_t, plot_qpar_vs_z_t,
    animate_dens_vs_z, animate_upar_vs_z,
    animate_f_vs_vpa_z, animate_f_vs_vpa_z0, animate_f_vs_z0_vpa,
    animate_deltaf_vs_vpa_z, animate_deltaf_vs_vpa_z0, animate_deltaf_vs_vpa_z0,
    animate_f_vs_vpa_r, animate_f_vs_vperp_z, animate_f_vs_vperp_r,
    animate_f_vs_vperp_vpa, animate_f_vs_r_z, animate_f_vs_vz_z, animate_f_vs_vr_r,
    animate_Er_vs_r_z, animate_Ez_vs_r_z, animate_phi_vs_r_z,
    nwrite_movie, itime_min, itime_max, ivpa0, ivperp0, iz0, ir0, ivz0, ivr0, ivzeta0)

end

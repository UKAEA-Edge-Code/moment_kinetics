"""
"""
module velocity_moments

export integrate_over_vspace
export integrate_over_positive_vpa, integrate_over_negative_vpa
export integrate_over_positive_vz, integrate_over_negative_vz
export create_moments_chrg, create_moments_ntrl
export update_moments!
export update_density!
export update_upar!
export update_ppar!
export update_pperp!
export update_qpar!
export update_vth!
export reset_moments_status!
export enforce_moment_constraints!
export moments_chrg_substruct, moments_ntrl_substruct
export update_neutral_density!
export update_neutral_uz!
export update_neutral_ur!
export update_neutral_uzeta!
export update_neutral_pz!
export update_neutral_pr!
export update_neutral_pzeta!
export update_neutral_qz!

# for testing 
export get_density
export get_upar
export get_ppar
export get_pperp
export get_pressure
export get_qpar

using ..type_definitions: mk_float
using ..array_allocation: allocate_shared_float, allocate_bool
using ..calculus: integral
using ..communication
using ..communication: _block_synchronize
using ..looping

#global tmpsum1 = 0.0
#global tmpsum2 = 0.0
#global dens_hist = zeros(17,1)
#global n_hist = 0

"""
"""
mutable struct moments_charged_substruct
    # this is the particle density
    dens::MPISharedArray{mk_float,3}
    # this is the parallel flow
    upar::MPISharedArray{mk_float,3}
    # this is the parallel pressure
    ppar::MPISharedArray{mk_float,3}
    # this is the perpendicular pressure
    pperp::MPISharedArray{mk_float,3}
    # this is the parallel heat flux
    qpar::MPISharedArray{mk_float,3}
    # this is the thermal speed based on the parallel temperature Tpar = ppar/dens: vth = sqrt(2*Tpar/m)
    vth::MPISharedArray{mk_float,3}
    # this is the entropy production dS/dt = - int (ln f sum_s' C_ss' [f_s,f_s']) d^3 v
    dSdt::MPISharedArray{mk_float,3}
end

"""
"""
mutable struct moments_neutral_substruct
    # this is the particle density
    dens::MPISharedArray{mk_float,3}
    # this is the particle mean velocity in z 
    uz::MPISharedArray{mk_float,3}
    # this is the particle mean velocity in r 
    ur::MPISharedArray{mk_float,3}
    # this is the particle mean velocity in zeta 
    uzeta::MPISharedArray{mk_float,3}
    # this is the zz particle pressure tensor component 
    pz::MPISharedArray{mk_float,3}
    # this is the rr particle pressure tensor component 
    pr::MPISharedArray{mk_float,3}
    # this is the zetazeta particle pressure tensor component 
    pzeta::MPISharedArray{mk_float,3}
    # this is the total (isotropic) particle pressure 
    ptot::MPISharedArray{mk_float,3}
    # this is the thermal speed based on the temperature T = ptot/dens: vth = sqrt(2*T/m)
    vth::MPISharedArray{mk_float,3}
    # this is the heat flux along z
    qz::MPISharedArray{mk_float,3}
end

"""
"""
function create_moments_charged(nz, nr, n_species)
    # allocate array used for the particle density
    density = allocate_shared_float(nz, nr, n_species)
    # allocate array used for the parallel flow
    parallel_flow = allocate_shared_float(nz, nr, n_species)
    # allocate array used for the parallel pressure
    parallel_pressure = allocate_shared_float(nz, nr, n_species)
    # allocate array used for the perpendicular pressure
    perpendicular_pressure = allocate_shared_float(nz, nr, n_species)
    # allocate array used for the parallel flow
    parallel_heat_flux = allocate_shared_float(nz, nr, n_species)
    # allocate array of Bools that indicate if the parallel flow is updated for each species
    # allocate array used for the thermal speed
    thermal_speed = allocate_shared_float(nz, nr, n_species)
    entropy_production = allocate_shared_float(nz, nr, n_species)
    # return struct containing arrays needed to update moments
    return moments_charged_substruct(density, parallel_flow, parallel_pressure,
     perpendicular_pressure, parallel_heat_flux, thermal_speed, entropy_production)
end

# neutral particles have natural mean velocities 
# uz, ur, uzeta =/= upar 
# and similarly for heat fluxes
# therefore separate moments object for neutrals 
    
function create_moments_neutral(nz, nr, n_species)
    # allocate array used for the particle density
    density = allocate_shared_float(nz, nr, n_species)
    uz = allocate_shared_float(nz, nr, n_species)
    ur = allocate_shared_float(nz, nr, n_species)
    uzeta = allocate_shared_float(nz, nr, n_species)
    pz = allocate_shared_float(nz, nr, n_species)
    pr = allocate_shared_float(nz, nr, n_species)
    pzeta = allocate_shared_float(nz, nr, n_species)
    ptot = allocate_shared_float(nz, nr, n_species)
    vth = allocate_shared_float(nz, nr, n_species)
    qz = allocate_shared_float(nz, nr, n_species)
    # return struct containing arrays needed to update moments
    return moments_neutral_substruct(density,uz,ur,uzeta,pz,pr,pzeta,ptot,vth,qz)
end

"""
calculate the updated density (dens) and parallel pressure (ppar) for all species
"""
function update_moments!(moments, ff, vpa, nz, nr, composition)
    n_species = size(ff,4)
    @boundscheck n_species == size(moments.dens,3) || throw(BoundsError(moments))
    @loop_s is begin
        if moments.dens_updated[is] == false
            @views update_density_species!(moments.dens[:,:,is], ff[:,:,:,is], vpa, z, r)
            moments.dens_updated[is] = true
        end
        if moments.upar_updated[is] == false
            @views update_upar_species!(moments.upar[:,:,is], ff[:,:,:,is], vpa, z, r, moments.dens[:,:,is])
            moments.upar_updated[is] = true
        end
        if moments.ppar_updated[is] == false
            @views update_ppar_species!(moments.ppar[:,:,is], ff[:,:,:,is], vpa, z, r, moments.upar[:,:,is])
            moments.ppar_updated[is] = true
        end
        @. moments.vth = sqrt(moments.ppar/moments.dens)
        if moments.qpar_updated[is] == false
            @views update_qpar_species!(moments.qpar[:,is], ff[:,:,is], vpa, z, r, moments.vpa_norm_fac[:,:,is])
            moments.qpar_updated[is] = true
        end
    end
    return nothing
end

"""
NB: if this function is called and if dens_updated is false, then
the incoming pdf is the un-normalized pdf that satisfies int dv pdf = density
"""
function update_density!(dens, pdf, vpa, vperp, z, r, composition)
    
    begin_s_r_z_region()
    
    n_species = size(pdf,5)
    @boundscheck n_species == size(dens,3) || throw(BoundsError(dens))
    @loop_s is begin
        @views update_density_species!(dens[:,:,is], pdf[:,:,:,:,is], vpa, vperp, z, r)
    end
end

"""
calculate the updated density (dens) for a given species
"""
function update_density_species!(dens, ff, vpa, vperp, z, r)
    @boundscheck vpa.n == size(ff, 1) || throw(BoundsError(ff))
    @boundscheck vperp.n == size(ff, 2) || throw(BoundsError(ff))
    @boundscheck z.n == size(ff, 3) || throw(BoundsError(ff))
    @boundscheck r.n == size(ff, 4) || throw(BoundsError(ff))
    @boundscheck z.n == size(dens, 1) || throw(BoundsError(dens))
    @boundscheck r.n == size(dens, 2) || throw(BoundsError(dens))
    @loop_r_z ir iz begin
        #dens[iz,ir] = integrate_over_vspace(@view(ff[:,:,iz,ir]), 
        # vpa.grid, 0, vpa.wgts, vperp.grid, 0, vperp.wgts)
        dens[iz,ir] = get_density(@view(ff[:,:,iz,ir]), vpa, vperp)
    end
    return nothing
end

function get_density(ff, vpa, vperp)
    return integrate_over_vspace(@view(ff[:,:]), vpa.grid, 0, vpa.wgts, vperp.grid, 0, vperp.wgts)
end

"""
NB: if this function is called and if upar_updated is false, then
the incoming pdf is the un-normalized pdf that satisfies int dv pdf = density
"""
function update_upar!(upar, pdf, vpa, vperp, z, r, composition, density)
    
    begin_s_r_z_region()
    
    n_species = size(pdf,5)
    @boundscheck n_species == size(upar,3) || throw(BoundsError(upar))
    @loop_s is begin
        @views update_upar_species!(upar[:,:,is], pdf[:,:,:,:,is], vpa, vperp, z, r, density[:,:,is])
    end
end

"""
calculate the updated parallel flow (upar) for a given species
"""
function update_upar_species!(upar, ff, vpa, vperp, z, r, density)
    @boundscheck vpa.n == size(ff, 1) || throw(BoundsError(ff))
    @boundscheck vperp.n == size(ff, 2) || throw(BoundsError(ff))
    @boundscheck z.n == size(ff, 3) || throw(BoundsError(ff))
    @boundscheck r.n == size(ff, 4) || throw(BoundsError(ff))
    @boundscheck z.n == size(upar, 1) || throw(BoundsError(upar))
    @boundscheck r.n == size(upar, 2) || throw(BoundsError(upar))
    @loop_r_z ir iz begin
        #upar[iz,ir] = integrate_over_vspace(@view(ff[:,:,iz,ir]), 
        # vpa.grid, 1, vpa.wgts, vperp.grid, 0, vperp.wgts)
        upar[iz,ir] = get_upar(@view(ff[:,:,iz,ir]), vpa, vperp, density[iz,ir])
    end
    return nothing
end

function get_upar(ff, vpa, vperp, density)
    upar = integrate_over_vspace(@view(ff[:,:]), vpa.grid, 1, vpa.wgts, vperp.grid, 0, vperp.wgts)
    upar /= density
    return upar
end

"""
"""
function update_ppar!(ppar, pdf, vpa, vperp, z, r, composition, upar)
    @boundscheck composition.n_ion_species == size(ppar,3) || throw(BoundsError(ppar))
    @boundscheck r.n == size(ppar,2) || throw(BoundsError(ppar))
    @boundscheck z.n == size(ppar,1) || throw(BoundsError(ppar))
    
    begin_s_r_z_region()
    
    @loop_s is begin
        @views update_ppar_species!(ppar[:,:,is], pdf[:,:,:,:,is], vpa, vperp, z, r, upar[:,:,is])
    end
end

"""
calculate the updated parallel pressure (ppar) for a given species
"""
function update_ppar_species!(ppar, ff, vpa, vperp, z, r, upar)
    @boundscheck vpa.n == size(ff, 1) || throw(BoundsError(ff))
    @boundscheck vperp.n == size(ff, 2) || throw(BoundsError(ff))
    @boundscheck z.n == size(ff, 3) || throw(BoundsError(ff))
    @boundscheck r.n == size(ff, 4) || throw(BoundsError(ff))
    @boundscheck z.n == size(ppar, 1) || throw(BoundsError(ppar))
    @boundscheck r.n == size(ppar, 2) || throw(BoundsError(ppar))
    mass = 1.0 # only reference mass currently supported for all species
    @loop_r_z ir iz begin
        #ppar[iz,ir] = integrate_over_vspace(@view(ff[:,:,iz,ir]), 
        # vpa.grid, 2, vpa.wgts, vperp.grid, 0, vperp.wgts)
        ppar[iz,ir] = get_ppar(@view(ff[:,:,iz,ir]), vpa, vperp, upar[iz,ir], mass)
    end
    return nothing
end

function get_ppar(ff, vpa, vperp, upar, mass)
    @. vpa.scratch = vpa.grid - upar
    return 2.0*mass*integrate_over_vspace(@view(ff[:,:]), vpa.scratch, 2, vpa.wgts, vperp.grid, 0, vperp.wgts)
end

function update_pperp!(pperp, pdf, vpa, vperp, z, r, composition)
    @boundscheck composition.n_ion_species == size(pperp,3) || throw(BoundsError(pperp))
    @boundscheck r.n == size(pperp,2) || throw(BoundsError(pperp))
    @boundscheck z.n == size(pperp,1) || throw(BoundsError(pperp))
    
    begin_s_r_z_region()
    
    @loop_s is begin
        @views update_pperp_species!(pperp[:,:,is], pdf[:,:,:,:,is], vpa, vperp, z, r)
    end
end

"""
calculate the updated perpendicular pressure (pperp) for a given species
"""
function update_pperp_species!(pperp, ff, vpa, vperp, z, r)
    @boundscheck vpa.n == size(ff, 1) || throw(BoundsError(ff))
    @boundscheck vperp.n == size(ff, 2) || throw(BoundsError(ff))
    @boundscheck z.n == size(ff, 3) || throw(BoundsError(ff))
    @boundscheck r.n == size(ff, 4) || throw(BoundsError(ff))
    @boundscheck z.n == size(pperp, 1) || throw(BoundsError(pperp))
    @boundscheck r.n == size(pperp, 2) || throw(BoundsError(pperp))
    mass = 1.0 # only reference mass currently supported for all species
    @loop_r_z ir iz begin
        pperp[iz,ir] = get_pperp(@view(ff[:,:,iz,ir]), vpa, vperp, mass)
    end
    return nothing
end

function get_pperp(ff, vpa, vperp, mass)
    return mass*integrate_over_vspace(@view(ff[:,:]), vpa.grid, 0, vpa.wgts, vperp.grid, 2, vperp.wgts)
end

function update_vth!(vth, ppar, pperp, dens, vperp, z, r, composition)
    @boundscheck composition.n_ion_species == size(vth,3) || throw(BoundsError(vth))
    @boundscheck r.n == size(vth,2) || throw(BoundsError(vth))
    @boundscheck z.n == size(vth,1) || throw(BoundsError(vth))
    mass = 1.0 # only reference mass currently supported for all species
    begin_s_r_z_region()
    
    if vperp.n > 1 #2V definition
        @loop_s_r_z is ir iz begin
            piso = get_pressure(ppar[iz,ir,is],pperp[iz,ir,is])
            vth[iz,ir,is] = sqrt(piso/(mass*dens[iz,ir,is]))
        end
    else #1V definition 
        @loop_s_r_z is ir iz begin
            vth[iz,ir,is] = sqrt(ppar[iz,ir,is]/(mass*dens[iz,ir,is]))
        end
    end
end

"""
compute the isotropic pressure from the already computed ppar and pperp
"""
function get_pressure(ppar::mk_float,pperp::mk_float)
    pres = (1.0/3.0)*(ppar + 2.0*pperp) 
    return pres
end

"""
NB: if this function is called and if ppar_updated is false, then
the incoming pdf is the un-normalized pdf that satisfies int dv pdf = density
"""
function update_qpar!(qpar, pdf, vpa, vperp, z, r, composition, upar, dummy_vpavperp)
    @boundscheck composition.n_ion_species == size(qpar,3) || throw(BoundsError(qpar))
    
    begin_s_r_z_region()

    @loop_s is begin
        @views update_qpar_species!(qpar[:,:,is], pdf[:,:,:,:,is], vpa, vperp, z, r, upar[:,:,is], dummy_vpavperp)
    end
end

"""
calculate the updated parallel heat flux (qpar) for a given species
"""
function update_qpar_species!(qpar, ff, vpa, vperp, z, r, upar, dummy_vpavperp)
    @boundscheck r.n == size(ff, 4) || throw(BoundsError(ff))
    @boundscheck z.n == size(ff, 3) || throw(BoundsError(ff))
    @boundscheck vperp.n == size(ff, 2) || throw(BoundsError(ff))
    @boundscheck vpa.n == size(ff, 1) || throw(BoundsError(ff))
    @boundscheck r.n == size(qpar, 2) || throw(BoundsError(qpar))
    @boundscheck z.n == size(qpar, 1) || throw(BoundsError(qpar))
    
    mass = 1.0 # only reference mass currently supported for all species
    if vperp.n > 1
        @loop_r_z ir iz begin
            # old ! qpar[iz,ir] = integrate_over_vspace(@view(ff[:,iz,ir]), vpa.grid, 3, vpa.wgts) * vpanorm[iz,ir]^4
            #qpar[iz,ir] = integrate_over_vspace(@view(ff[:,:,iz,ir]),
            # vpa.grid, 3, vpa.wgts, vperp.grid, 0, vperp.wgts)
            @views qpar[iz,ir] = get_qpar(ff[:,:,iz,ir], vpa, vperp, upar[iz,ir], mass, dummy_vpavperp)
        end
    else #1V definitions
        @loop_r_z ir iz begin
            qpar[iz,ir] = get_qpar_1V(@view(ff[:,:,iz,ir]), vpa, vperp, upar[iz,ir], mass)
        end
    end
    return nothing
end

function get_qpar_1V(ff, vpa, vperp, upar, mass)
    @. vpa.scratch = vpa.grid - upar
    return mass*integrate_over_vspace(@view(ff[:,:]), vpa.scratch, 3, vpa.wgts, vperp.grid, 0, vperp.wgts)
end

function get_qpar(ff, vpa, vperp, upar, mass, dummy_vpavperp)
    @loop_vperp_vpa ivperp ivpa begin
        wpar = vpa.grid[ivpa]-upar
        dummy_vpavperp[ivpa,ivperp] = ff[ivpa,ivperp]*wpar*( wpar^2 + vperp.grid[ivperp]^2)
    end
    return mass*integrate_over_vspace(@view(dummy_vpavperp[:,:]), vpa.grid, 0, vpa.wgts, vperp.grid, 0, vperp.wgts)
end
"""
calculate the neutral density from the neutral pdf
"""
function update_neutral_density!(dens, pdf, vz, vr, vzeta, z, r, composition)
    
    begin_sn_r_z_region()
    @boundscheck composition.n_neutral_species == size(pdf, 6) || throw(BoundsError(pdf))
    @boundscheck composition.n_neutral_species == size(dens, 3) || throw(BoundsError(dens))
    @loop_sn isn begin
        @views update_neutral_density_species!(dens[:,:,isn], pdf[:,:,:,:,:,isn], vz, vr, vzeta, z, r)
    end
end

"""
calculate the updated density (dens) for a given species
"""
function update_neutral_density_species!(dens, ff, vz, vr, vzeta, z, r)
    @boundscheck vz.n == size(ff, 1) || throw(BoundsError(ff))
    @boundscheck vr.n == size(ff, 2) || throw(BoundsError(ff))
    @boundscheck vzeta.n == size(ff, 3) || throw(BoundsError(ff))
    @boundscheck z.n == size(ff, 4) || throw(BoundsError(ff))
    @boundscheck r.n == size(ff, 5) || throw(BoundsError(ff))
    @boundscheck z.n == size(dens, 1) || throw(BoundsError(dens))
    @boundscheck r.n == size(dens, 2) || throw(BoundsError(dens))
    @loop_r_z ir iz begin
        dens[iz,ir] = integrate_over_neutral_vspace(@view(ff[:,:,:,iz,ir]), 
         vz.grid, 0, vz.wgts, vr.grid, 0, vr.wgts, vzeta.grid, 0, vzeta.wgts)
    end
    return nothing
end

function update_neutral_uz!(uz, pdf, vz, vr, vzeta, z, r, composition)
    
    begin_sn_r_z_region()
    @boundscheck composition.n_neutral_species == size(pdf, 6) || throw(BoundsError(pdf))
    @boundscheck composition.n_neutral_species == size(uz, 3) || throw(BoundsError(uz))
    @loop_sn isn begin
        @views update_neutral_uz_species!(uz[:,:,isn], pdf[:,:,:,:,:,isn], vz, vr, vzeta, z, r)
    end
end

"""
calculate the updated uz (mean velocity in z) for a given species
"""
function update_neutral_uz_species!(uz, ff, vz, vr, vzeta, z, r)
    @boundscheck vz.n == size(ff, 1) || throw(BoundsError(ff))
    @boundscheck vr.n == size(ff, 2) || throw(BoundsError(ff))
    @boundscheck vzeta.n == size(ff, 3) || throw(BoundsError(ff))
    @boundscheck z.n == size(ff, 4) || throw(BoundsError(ff))
    @boundscheck r.n == size(ff, 5) || throw(BoundsError(ff))
    @boundscheck z.n == size(uz, 1) || throw(BoundsError(uz))
    @boundscheck r.n == size(uz, 2) || throw(BoundsError(uz))
    @loop_r_z ir iz begin
        uz[iz,ir] = integrate_over_neutral_vspace(@view(ff[:,:,:,iz,ir]), 
         vz.grid, 1, vz.wgts, vr.grid, 0, vr.wgts, vzeta.grid, 0, vzeta.wgts)
    end
    return nothing
end

function update_neutral_ur!(ur, pdf, vz, vr, vzeta, z, r, composition)
    
    begin_sn_r_z_region()
    @boundscheck composition.n_neutral_species == size(pdf, 6) || throw(BoundsError(pdf))
    @boundscheck composition.n_neutral_species == size(ur, 3) || throw(BoundsError(ur))
    @loop_sn isn begin
        @views update_neutral_ur_species!(ur[:,:,isn], pdf[:,:,:,:,:,isn], vz, vr, vzeta, z, r)
    end
end

"""
calculate the updated ur (mean velocity in r) for a given species
"""
function update_neutral_ur_species!(ur, ff, vz, vr, vzeta, z, r)
    @boundscheck vz.n == size(ff, 1) || throw(BoundsError(ff))
    @boundscheck vr.n == size(ff, 2) || throw(BoundsError(ff))
    @boundscheck vzeta.n == size(ff, 3) || throw(BoundsError(ff))
    @boundscheck z.n == size(ff, 4) || throw(BoundsError(ff))
    @boundscheck r.n == size(ff, 5) || throw(BoundsError(ff))
    @boundscheck z.n == size(ur, 1) || throw(BoundsError(ur))
    @boundscheck r.n == size(ur, 2) || throw(BoundsError(ur))
    @loop_r_z ir iz begin
        ur[iz,ir] = integrate_over_neutral_vspace(@view(ff[:,:,:,iz,ir]), 
         vz.grid, 0, vz.wgts, vr.grid, 1, vr.wgts, vzeta.grid, 0, vzeta.wgts)
    end
    return nothing
end

function update_neutral_uzeta!(uzeta, pdf, vz, vr, vzeta, z, r, composition)
    
    begin_sn_r_z_region()
    @boundscheck composition.n_neutral_species == size(pdf, 6) || throw(BoundsError(pdf))
    @boundscheck composition.n_neutral_species == size(uzeta, 3) || throw(BoundsError(uzeta))
    @loop_sn isn begin
        @views update_neutral_uzeta_species!(uzeta[:,:,isn], pdf[:,:,:,:,:,isn], vz, vr, vzeta, z, r)
    end
end

"""
calculate the updated uzeta (mean velocity in zeta) for a given species
"""
function update_neutral_uzeta_species!(uzeta, ff, vz, vr, vzeta, z, r)
    @boundscheck vz.n == size(ff, 1) || throw(BoundsError(ff))
    @boundscheck vr.n == size(ff, 2) || throw(BoundsError(ff))
    @boundscheck vzeta.n == size(ff, 3) || throw(BoundsError(ff))
    @boundscheck z.n == size(ff, 4) || throw(BoundsError(ff))
    @boundscheck r.n == size(ff, 5) || throw(BoundsError(ff))
    @boundscheck z.n == size(uzeta, 1) || throw(BoundsError(uzeta))
    @boundscheck r.n == size(uzeta, 2) || throw(BoundsError(uzeta))
    @loop_r_z ir iz begin
        uzeta[iz,ir] = integrate_over_neutral_vspace(@view(ff[:,:,:,iz,ir]), 
         vz.grid, 0, vz.wgts, vr.grid, 0, vr.wgts, vzeta.grid, 1, vzeta.wgts)
    end
    return nothing
end

function update_neutral_pz!(pz, pdf, vz, vr, vzeta, z, r, composition)
    @boundscheck r.n == size(pz,2) || throw(BoundsError(pz))
    @boundscheck z.n == size(pz,1) || throw(BoundsError(pz))
    
    begin_sn_r_z_region()
    @boundscheck composition.n_neutral_species == size(pdf, 6) || throw(BoundsError(pdf))
    @boundscheck composition.n_neutral_species == size(pz, 3) || throw(BoundsError(pz))
    
    @loop_sn isn begin
        @views update_neutral_pz_species!(pz[:,:,isn], pdf[:,:,:,:,:,isn], vz, vr, vzeta, z, r)
    end
end

"""
calculate the updated pressure in zz direction (pz) for a given species
"""
function update_neutral_pz_species!(pz, ff, vz, vr, vzeta, z, r)
    @boundscheck vz.n == size(ff, 1) || throw(BoundsError(ff))
    @boundscheck vr.n == size(ff, 2) || throw(BoundsError(ff))
    @boundscheck vzeta.n == size(ff, 3) || throw(BoundsError(ff))
    @boundscheck z.n == size(ff, 4) || throw(BoundsError(ff))
    @boundscheck r.n == size(ff, 5) || throw(BoundsError(ff))
    @boundscheck z.n == size(pz, 1) || throw(BoundsError(pz))
    @boundscheck r.n == size(pz, 2) || throw(BoundsError(pz))
    @loop_r_z ir iz begin
        pz[iz,ir] = integrate_over_neutral_vspace(@view(ff[:,:,:,iz,ir]),
         vz.grid, 2, vz.wgts, vr.grid, 0, vr.wgts, vzeta.grid, 0, vzeta.wgts)
    end
    return nothing
end

function update_neutral_pr!(pr, pdf, vz, vr, vzeta, z, r, composition)
    @boundscheck r.n == size(pr,2) || throw(BoundsError(pr))
    @boundscheck z.n == size(pr,1) || throw(BoundsError(pr))
    
    begin_sn_r_z_region()
    @boundscheck composition.n_neutral_species == size(pdf, 6) || throw(BoundsError(pdf))
    @boundscheck composition.n_neutral_species == size(pr, 3) || throw(BoundsError(pr))
    
    @loop_sn isn begin
        @views update_neutral_pr_species!(pr[:,:,isn], pdf[:,:,:,:,:,isn], vz, vr, vzeta, z, r)
    end
end

"""
calculate the updated pressure in the rr direction (pr) for a given species
"""
function update_neutral_pr_species!(pr, ff, vz, vr, vzeta, z, r)
    @boundscheck vz.n == size(ff, 1) || throw(BoundsError(ff))
    @boundscheck vr.n == size(ff, 2) || throw(BoundsError(ff))
    @boundscheck vzeta.n == size(ff, 3) || throw(BoundsError(ff))
    @boundscheck z.n == size(ff, 4) || throw(BoundsError(ff))
    @boundscheck r.n == size(ff, 5) || throw(BoundsError(ff))
    @boundscheck z.n == size(pr, 1) || throw(BoundsError(pr))
    @boundscheck r.n == size(pr, 2) || throw(BoundsError(pr))
    @loop_r_z ir iz begin
        pr[iz,ir] = integrate_over_neutral_vspace(@view(ff[:,:,:,iz,ir]),
         vz.grid, 0, vz.wgts, vr.grid, 2, vr.wgts, vzeta.grid, 0, vzeta.wgts)
    end
    return nothing
end

function update_neutral_pzeta!(pzeta, pdf, vz, vr, vzeta, z, r, composition)
    @boundscheck r.n == size(pzeta,2) || throw(BoundsError(pzeta))
    @boundscheck z.n == size(pzeta,1) || throw(BoundsError(pzeta))
    
    begin_sn_r_z_region()
    @boundscheck composition.n_neutral_species == size(pdf, 6) || throw(BoundsError(pdf))
    @boundscheck composition.n_neutral_species == size(pzeta, 3) || throw(BoundsError(pzeta))
    
    @loop_sn isn begin
        @views update_neutral_pzeta_species!(pzeta[:,:,isn], pdf[:,:,:,:,:,isn], vz, vr, vzeta, z, r)
    end
end

"""
calculate the updated pressure in the zeta zeta direction (pzeta) for a given species
"""
function update_neutral_pzeta_species!(pzeta, ff, vz, vr, vzeta, z, r)
    @boundscheck vz.n == size(ff, 1) || throw(BoundsError(ff))
    @boundscheck vr.n == size(ff, 2) || throw(BoundsError(ff))
    @boundscheck vzeta.n == size(ff, 3) || throw(BoundsError(ff))
    @boundscheck z.n == size(ff, 4) || throw(BoundsError(ff))
    @boundscheck r.n == size(ff, 5) || throw(BoundsError(ff))
    @boundscheck z.n == size(pzeta, 1) || throw(BoundsError(pzeta))
    @boundscheck r.n == size(pzeta, 2) || throw(BoundsError(pzeta))
    @loop_r_z ir iz begin
        pzeta[iz,ir] = integrate_over_neutral_vspace(@view(ff[:,:,:,iz,ir]),
         vz.grid, 0, vz.wgts, vr.grid, 0, vr.wgts, vzeta.grid, 2, vzeta.wgts)
    end
    return nothing
end

function update_neutral_qz!(qz, pdf, vz, vr, vzeta, z, r, composition)
    @boundscheck r.n == size(qz,2) || throw(BoundsError(qz))
    @boundscheck z.n == size(qz,1) || throw(BoundsError(qz))
    
    begin_sn_r_z_region()
    @boundscheck composition.n_neutral_species == size(pdf, 6) || throw(BoundsError(pdf))
    @boundscheck composition.n_neutral_species == size(qz, 3) || throw(BoundsError(qz))
    
    @loop_sn isn begin
        @views update_neutral_qz_species!(qz[:,:,isn], pdf[:,:,:,:,:,isn], vz, vr, vzeta, z, r)
    end
end

"""
calculate the updated heat flux zzz direction (qz) for a given species
"""
function update_neutral_qz_species!(qz, ff, vz, vr, vzeta, z, r)
    @boundscheck vz.n == size(ff, 1) || throw(BoundsError(ff))
    @boundscheck vr.n == size(ff, 2) || throw(BoundsError(ff))
    @boundscheck vzeta.n == size(ff, 3) || throw(BoundsError(ff))
    @boundscheck z.n == size(ff, 4) || throw(BoundsError(ff))
    @boundscheck r.n == size(ff, 5) || throw(BoundsError(ff))
    @boundscheck z.n == size(qz, 1) || throw(BoundsError(qz))
    @boundscheck r.n == size(qz, 2) || throw(BoundsError(qz))
    @loop_r_z ir iz begin
        qz[iz,ir] = integrate_over_neutral_vspace(@view(ff[:,:,:,iz,ir]),
         vz.grid, 3, vz.wgts, vr.grid, 0, vr.wgts, vzeta.grid, 0, vzeta.wgts)
    end
    return nothing
end


"""
computes the integral over vpa of the integrand, using the input vpa_wgts
"""
function integrate_over_vspace(args...)
    return integral(args...)/sqrt(pi)
end
# factor of Pi^3/2 assumes normalisation f^N_neutral = Pi^3/2 c_neutral^3 f_neutral / n_ref 
# For 1D case we multiply wgts of vr & vzeta by sqrt(pi) to return
# to 1D normalisation f^N_neutral = Pi^1/2 c_neutral f_neutral / n_ref 
function integrate_over_neutral_vspace(args...)
    return integral(args...)/(sqrt(pi)^3)
end

"""
computes the integral over vpa >= 0 of the integrand, using the input vpa_wgts
this could be made more efficient for the case that dz/dt = vpa is time-independent,
but it has been left general for the cases where, e.g., dz/dt = wpa*vth + upar
varies in time
"""
function integrate_over_positive_vpa(integrand, dzdt, vpa_wgts, wgts_mod, vperp_grid, vperp_wgts)
    # define the nvpa variable for convenience
    nvpa = length(vpa_wgts)
    nvperp = length(vperp_wgts)
    # define an approximation to zero that allows for finite-precision arithmetic
    zero = -1.0e-8
    # if dzdt at the maximum vpa index is negative, then dzdt < 0 everywhere
    # the integral over positive dzdt is thus zero, as we assume the distribution
    # function is zero beyond the simulated vpa domain
    if dzdt[nvpa] < zero
        velocity_integral = 0.0
    else
        # do bounds checks on arrays that will be used in the below loop
        @boundscheck nvpa == size(integrand,1) || throw(BoundsError(integrand))
        @boundscheck nvperp == size(integrand,2) || throw(BoundsError(integrand))
        @boundscheck nvpa == length(dzdt) || throw(BoundsError(dzdt))
        @boundscheck nvpa == length(wgts_mod) || throw(BoundsError(wgts_mod))
        # initialise the integration weights, wgts_mod, to be the input vpa_wgts
        # this will only change at the dzdt = 0 point, if it exists on the grid
        @. wgts_mod = vpa_wgts
        # ivpa_zero will be the minimum index for which dzdt[ivpa_zero] >= 0
        ivpa_zero = nvpa
        @inbounds for ivpa ∈ 1:nvpa
            if dzdt[ivpa] >= zero
                ivpa_zero = ivpa
                # if dzdt = 0, need to divide its associated integration
                # weight by a factor of 2 to avoid double-counting
                if abs(dzdt[ivpa]) < abs(zero)
                    wgts_mod[ivpa] /= 2.0
                end
                break
            end
        end
        @views velocity_integral = integrate_over_vspace(integrand[ivpa_zero:end,:], 
          dzdt[ivpa_zero:end], 0, wgts_mod[ivpa_zero:end], vperp_grid, 0, vperp_wgts)
        # n.b. we pass more arguments than might appear to be required here
        # to avoid needing a special integral function definition
        # the 0 integers are the powers by which dzdt and vperp_grid are raised to in the integral
    end
    return velocity_integral
end

function integrate_over_positive_vz(integrand, dzdt, vz_wgts, wgts_mod, 
 vr_grid, vr_wgts, vzeta_grid, vzeta_wgts)
    # define the nvz nvr nvzeta variable for convenience
    nvz = length(vz_wgts)
    nvr = length(vr_wgts)
    nvzeta = length(vzeta_wgts)
    # define an approximation to zero that allows for finite-precision arithmetic
    zero = -1.0e-8
    # if dzdt at the maximum vz index is negative, then dzdt < 0 everywhere
    # the integral over positive dzdt is thus zero, as we assume the distribution
    # function is zero beyond the simulated vpa domain
    if dzdt[nvz] < zero
        velocity_integral = 0.0
    else
        # do bounds checks on arrays that will be used in the below loop
        @boundscheck nvz == size(integrand,1) || throw(BoundsError(integrand))
        @boundscheck nvr == size(integrand,2) || throw(BoundsError(integrand))
        @boundscheck nvzeta == size(integrand,3) || throw(BoundsError(integrand))
        @boundscheck nvz == length(dzdt) || throw(BoundsError(dzdt))
        @boundscheck nvz == length(wgts_mod) || throw(BoundsError(wgts_mod))
        # initialise the integration weights, wgts_mod, to be the input vz_wgts
        # this will only change at the dzdt = 0 point, if it exists on the grid
        @. wgts_mod = vz_wgts
        # ivz_zero will be the minimum index for which dzdt[ivz_zero] >= 0
        ivz_zero = nvz
        @inbounds for ivz ∈ 1:nvz
            if dzdt[ivz] >= zero
                ivz_zero = ivz
                # if dzdt = 0, need to divide its associated integration
                # weight by a factor of 2 to avoid double-counting
                if abs(dzdt[ivz]) < abs(zero)
                    wgts_mod[ivz] /= 2.0
                end
                break
            end
        end
        @views velocity_integral = integrate_over_neutral_vspace(integrand[ivz_zero:end,:,:], 
          dzdt[ivz_zero:end], 0, wgts_mod[ivz_zero:end], vr_grid, 0, vr_wgts, vzeta_grid, 0, vzeta_wgts)
        # n.b. we pass more arguments than might appear to be required here
        # to avoid needing a special integral function definition
        # the 0 integers are the powers by which dzdt vr_grid and vzeta_grid are raised to in the integral
    end
    return velocity_integral
end

"""
computes the integral over vpa <= 0 of the integrand, using the input vpa_wgts
this could be made more efficient for the case that dz/dt = vpa is time-independent,
but it has been left general for the cases where, e.g., dz/dt = wpa*vth + upar
varies in time
"""
function integrate_over_negative_vpa(integrand, dzdt, vpa_wgts, wgts_mod, vperp_grid, vperp_wgts)
    # define the nvpa nvperp variables for convenience
    nvpa = length(vpa_wgts)
    nvperp = length(vperp_wgts)
    # define an approximation to zero that allows for finite-precision arithmetic
    zero = 1.0e-8
    # if dzdt at the mimimum vpa index is positive, then dzdt > 0 everywhere
    # the integral over negative dzdt is thus zero, as we assume the distribution
    # function is zero beyond the simulated vpa domain
    if dzdt[1] > zero
        velocity_integral = 0.0
    else
        # do bounds checks on arrays that will be used in the below loop
        @boundscheck nvpa == size(integrand,1) || throw(BoundsError(integrand))
        @boundscheck nvperp == size(integrand,2) || throw(BoundsError(integrand))
        @boundscheck nvpa == length(dzdt) || throw(BoundsError(dzdt))
        @boundscheck nvpa == length(wgts_mod) || throw(BoundsError(wgts_mod))
        # initialise the integration weights, wgts_mod, to be the input vpa_wgts
        # this will only change at the dzdt = 0 point, if it exists on the grid
        @. wgts_mod = vpa_wgts
        # ivpa_zero will be the maximum index for which dzdt[ivpa_zero] <= 0
        ivpa_zero = 1
        @inbounds for ivpa ∈ nvpa:-1:1
            if dzdt[ivpa] <= zero
                ivpa_zero = ivpa
                # if dzdt = 0, need to divide its associated integration
                # weight by a factor of 2 to avoid double-counting
                if abs(dzdt[ivpa]) < zero
                    wgts_mod[ivpa] /= 2.0
                end
                break
            end
        end
        @views velocity_integral = integrate_over_vspace(integrand[1:ivpa_zero,:], 
                dzdt[1:ivpa_zero], 0, wgts_mod[1:ivpa_zero], vperp_grid, 0, vperp_wgts)
        # n.b. we pass more arguments than might appear to be required here
        # to avoid needing a special integral function definition
        # the 0 integers are the powers by which dzdt and vperp_grid are raised to in the integral
    end
    return velocity_integral
end
function integrate_over_negative_vz(integrand, dzdt, vz_wgts, wgts_mod,
        vr_grid, vr_wgts, vzeta_grid, vzeta_wgts)
    # define the nvz nvr nvzeta variables for convenience
    nvz = length(vz_wgts)
    nvr = length(vr_wgts)
    nvzeta = length(vzeta_wgts)
    # define an approximation to zero that allows for finite-precision arithmetic
    zero = 1.0e-8
    # if dzdt at the mimimum vz index is positive, then dzdt > 0 everywhere
    # the integral over negative dzdt is thus zero, as we assume the distribution
    # function is zero beyond the simulated vpa domain
    if dzdt[1] > zero
        velocity_integral = 0.0
    else
        # do bounds checks on arrays that will be used in the below loop
        @boundscheck nvz == size(integrand,1) || throw(BoundsError(integrand))
        @boundscheck nvr == size(integrand,2) || throw(BoundsError(integrand))
        @boundscheck nvzeta == size(integrand,3) || throw(BoundsError(integrand))
        @boundscheck nvz == length(dzdt) || throw(BoundsError(dzdt))
        @boundscheck nvz == length(wgts_mod) || throw(BoundsError(wgts_mod))
        # initialise the integration weights, wgts_mod, to be the input vz_wgts
        # this will only change at the dzdt = 0 point, if it exists on the grid
        @. wgts_mod = vz_wgts
        # ivz_zero will be the maximum index for which dzdt[ivz_zero] <= 0
        ivz_zero = 1
        @inbounds for ivz ∈ nvz:-1:1
            if dzdt[ivz] <= zero
                ivz_zero = ivz
                # if dzdt = 0, need to divide its associated integration
                # weight by a factor of 2 to avoid double-counting
                if abs(dzdt[ivz]) < zero
                    wgts_mod[ivz] /= 2.0
                end
                break
            end
        end
        @views velocity_integral = integrate_over_neutral_vspace(integrand[1:ivz_zero,:,:], 
                dzdt[1:ivz_zero], 0, wgts_mod[1:ivz_zero], vr_grid, 0, vr_wgts, vzeta_grid, 0, vzeta_wgts)
        # n.b. we pass more arguments than might appear to be required here
        # to avoid needing a special integral function definition
        # the 0 integers are the powers by which dzdt and vperp_grid are raised to in the integral
    end
    return velocity_integral
end

"""
"""
function enforce_moment_constraints!(fvec_new, fvec_old, vpa, vperp, z, r, composition, moments, dummy)
    #global @. dens_hist += fvec_old.density
    #global n_hist += 1
    
    begin_s_r_z_region()
    
    # pre-calculate avgdens_ratio so that we don't read fvec_new.density[:,is] on every
    # process in the next loop - that would be an error because different processes
    # write to fvec_new.density[:,is]
    # This loop needs to be @loop_s_r because it fills the (not-shared)
    # dummy_sr buffer to be used within the @loop_s_r below, so the values
    # of is looped over by this process need to be the same.
    @loop_s_r is ir begin
        @views @. z.scratch = fvec_old.density[:,ir,is] - fvec_new.density[:,ir,is]
        @views dummy.dummy_sr[ir,is] = integral(z.scratch, z.wgts)/integral(fvec_old.density[:,ir,is], z.wgts)
    end
    # Need to call _block_synchronize() even though loop type does not change because
    # all spatial ranks read fvec_new.density, but it will be written below.
    _block_synchronize()

    @loop_s is begin
        @loop_r ir begin
            avgdens_ratio = dummy.dummy_sr[ir,is]
            @loop_z iz begin
                # Create views once to save overhead
                fnew_view = @view(fvec_new.pdf[:,:,iz,ir,is])
                fold_view = @view(fvec_old.pdf[:,:,iz,ir,is])

                # first calculate all of the integrals involving the updated pdf fvec_new.pdf
                density_integral = integrate_over_vspace(fnew_view, 
                 vpa.grid, 0, vpa.wgts, vperp.grid, 0, vperp.wgts)
                if moments.evolve_upar
                    upar_integral = integrate_over_vspace(fnew_view, 
                     vpa.grid, 1, vpa.wgts, vperp.grid, 0, vperp.wgts)
                end
                if moments.evolve_ppar
                    ppar_integral = integrate_over_vspace(fnew_view, 
                     vpa.grid, 2, vpa.wgts, vperp.grid, 0, vperp.wgts) - 0.5*density_integral
                end
                # update the pdf to account for the density-conserving correction
                @. fnew_view += fold_view * (1.0 - density_integral)
                if moments.evolve_upar
                    # next form the even part of the old distribution function that is needed
                    # to ensure momentum and energy conservation
                    @. dummy.dummy_vpavperp = fold_view
                    @loop_vperp ivperp begin
                        reverse!(dummy.dummy_vpavperp[:,ivperp])
                        @. dummy.dummy_vpavperp[:,ivperp] = 
                         0.5*(dummy.dummy_vpavperp[:,ivperp] + fold_view[:,ivperp])
                    end
                    # calculate the integrals involving this even pdf
                    vpa2_moment = integrate_over_vspace(dummy.dummy_vpavperp,
                     vpa.grid, 2, vpa.wgts, vperp.grid, 0, vperp.wgts)
                    upar_integral /= vpa2_moment
                    if moments.evolve_ppar
                        vpa4_moment = integrate_over_vspace(dummy.dummy_vpavperp, vpa.grid, 4, vpa.wgts, vperp.grid, 0, vperp.wgts) - 0.5 * vpa2_moment
                        ppar_integral /= vpa4_moment
                    end
                    # update the pdf to account for the momentum-conserving correction
                    @loop_vperp ivperp begin
                        @. fnew_view[:,ivperp] -= dummy.dummy_vpavperp[:,ivperp] * vpa.grid * upar_integral
                    end
                    if moments.evolve_ppar
                        @loop_vperp ivperp begin
                            # update the pdf to account for the energy-conserving correction
                            #@. fnew_view -= vpa.scratch * (vpa.grid^2 - 0.5) * ppar_integral
                            # Until julia-1.8 is released, prefer x*x to x^2 to avoid
                            # extra allocations when broadcasting.
                            @. fnew_view[:,ivperp] -= dummy.dummy_vpavperp[:,ivperp] * (vpa.grid * vpa.grid - 0.5) * ppar_integral
                        end
                    end
                end
                fvec_new.density[iz,ir,is] += fvec_old.density[iz,ir,is] * avgdens_ratio
                # update the thermal speed, as the density has changed
                moments.vth[iz,ir,is] = sqrt(2.0*fvec_new.ppar[iz,ir,is]/fvec_new.density[iz,ir,is])
            end
        end
        #global tmpsum1 += avgdens_ratio
        #@views avgdens_ratio2 = integral(fvec_old.density[:,is] .- fvec_new.density[:,is], z.wgts)#/integral(fvec_old.density[:,is], z.wgts)
        #global tmpsum2 += avgdens_ratio2
    end
    # the pdf, density and thermal speed have been changed so the corresponding parallel heat flux must be updated
    moments.qpar_updated .= false
    # update the parallel heat flux
    # NB: no longer need fvec_old.pdf so can use for temporary storage of un-normalised pdf
    if moments.evolve_ppar
        @loop_s is begin
            @loop_r ir begin
                @loop_z iz begin
                    fvec_old.temp_z_s[iz,ir,is] = fvec_new.density[iz,ir,is] / moments.vth[iz,ir,is]
                end
                @loop_z_vperp_vpa iz ivperp ivpa begin
                    fvec_old.pdf[ivpa,ivperp,iz,ir,is] = fvec_new.pdf[ivpa,ivperp,iz,ir,is] * fvec_old.temp_z_s[iz,ir,is]
                end
            end
        end
    elseif moments.evolve_density
        @loop_s_r_z_vperp_vpa is ir iz ivperp ivpa begin
            fvec_old.pdf[ivpa,ivperp,iz,ir,is] = fvec_new.pdf[ivpa,ivperp,iz,ir,is] * fvec_new.density[iz,ir,is]
        end
    else
        @loop_s_r_z_vperp_vpa is ir iz ivperp ivpa begin
            fvec_old.pdf[ivpa,ivperp,iz,ir,is] = fvec_new.pdf[ivpa,ivperp,iz,ir,is]
        end
    end
    update_qpar!(moments.qpar, moments.qpar_updated, fvec_old.pdf, vpa, vperp, z, r, composition, moments.vpa_norm_fac)
end

"""
"""
function reset_moments_status!(moments, composition, z)
    if moments.evolve_density == false
        moments.dens_updated .= false
    end
    if moments.evolve_upar == false
        moments.upar_updated .= false
    end
    if moments.evolve_ppar == false
        moments.ppar_updated .= false
    end
    moments.qpar_updated .= false
end

end

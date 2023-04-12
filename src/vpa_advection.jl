"""
"""
module vpa_advection

export vpa_advection!
export update_speed_vpa!

using ..advection: advance_f_local!
using ..communication
using ..looping

"""
"""
function vpa_advection!(f_out, fvec_in, fields, advect,
        vpa, mu, z, r, dt, vpa_spectral, composition, geometry)

    begin_s_r_z_mu_region()
    
    # only have a parallel acceleration term for neutrals if using the peculiar velocity
    # wpar = vpar - upar as a variable; i.e., d(wpar)/dt /=0 for neutrals even though d(vpar)/dt = 0.

    # calculate the advection speed corresponding to current f
    update_speed_vpa!(advect, fields, vpa, mu, z, r, composition, geometry)
    @loop_s is begin
        @loop_r_z_mu ir iz imu begin
            @views advance_f_local!(f_out[:,imu,iz,ir,is], fvec_in.pdf[:,imu,iz,ir,is],
                                    advect[is], imu, iz, ir, vpa, dt, vpa_spectral)
        end
    end
end

"""
calculate the advection speed in the vpa-direction at each grid point
"""
function update_speed_vpa!(advect, fields, vpa, mu, z, r, composition, geometry)
    @boundscheck r.n == size(advect[1].speed,4) || throw(BoundsError(advect))
    @boundscheck z.n == size(advect[1].speed,3) || throw(BoundsError(advect))
    @boundscheck mu.n == size(advect[1].speed,2) || throw(BoundsError(advect))
    #@boundscheck composition.n_ion_species == size(advect,2) || throw(BoundsError(advect))
    @boundscheck composition.n_ion_species == size(advect,1) || throw(BoundsError(advect))
    @boundscheck vpa.n == size(advect[1].speed,1) || throw(BoundsError(speed))
    if vpa.advection.option == "default"
        # dvpa/dt = Ze/m ⋅ E_parallel
        update_speed_default!(advect, fields, vpa, mu, z, r, composition, geometry)
    elseif vpa.advection.option == "constant"
        @serial_region begin
            # Not usually used - just run in serial
            # dvpa/dt = constant
            for is ∈ 1:composition.n_ion_species
                update_speed_constant!(advect[is], vpa, 1:mu.n, 1:z.n, 1:r.n)
            end
        end
        block_sychronize()
    elseif vpa.advection.option == "linear"
        @serial_region begin
            # Not usually used - just run in serial
            # dvpa/dt = constant ⋅ (vpa + L_vpa/2)
            for is ∈ 1:composition.n_ion_species
                update_speed_linear!(advect[is], vpa, 1:mu.n, 1:z.n, 1:r.n)
            end
        end
        block_sychronize()
    end
    @loop_s is begin
        @loop_r_z_mu ir iz imu begin
            @views @. advect[is].modified_speed[:,imu,iz,ir] = advect[is].speed[:,imu,iz,ir]
        end
    end
    return nothing
end

"""
"""
function update_speed_default!(advect, fields, vpa, mu, z, r, composition, geometry)
    bzed = geometry.bzed
    @inbounds @fastmath begin
        @loop_s is begin
            @loop_r ir begin
                # bzed = B_z/B
                @loop_z_mu iz imu begin
                    @views advect[is].speed[:,imu,iz,ir] .= 0.5*bzed*fields.Ez[iz,ir]
                end
            end
        end
    end

end

"""
update the advection speed dvpa/dt = constant
"""
function update_speed_constant!(advect, vpa, mu_range, z_range, r_range)
    #@inbounds @fastmath begin
    for ir ∈ r_range
        for iz ∈ z_range
            for imu ∈ mu_range
                @views advect.speed[:,imu,iz,ir] .= vpa.advection.constant_speed
            end
        end
    end
    #end
end

"""
update the advection speed dvpa/dt = const*(vpa + L/2)
"""
function update_speed_linear(advect, vpa, z_range, r_range)
    @inbounds @fastmath begin
        for ir ∈ r_range
            for iz ∈ z_range
                for imu ∈ mu_range
                    @views @. advect.speed[:,imu,iz,ir] = vpa.advection.constant_speed*(vpa.grid+0.5*vpa.L)
                end
            end
        end
    end
end

end

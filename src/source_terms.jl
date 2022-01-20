module source_terms

export source_terms!

using ..calculus: derivative!
using ..looping

function source_terms!(pdf_out, fvec_in, moments, vpa, z, r, dt, spectral, composition, CX_frequency)
    # calculate the source terms due to redefinition of the pdf to split off density,
    # and use them to update the pdf
    #n_species = size(pdf_out,3)
    if moments.evolve_ppar
        @s_r_z_loop_s is begin
            @views source_terms_evolve_ppar!(pdf_out[:,:,:,is], fvec_in.pdf[:,:,:,is],
                                             fvec_in.density[:,:,is], fvec_in.upar[:,:,is], fvec_in.ppar[:,:,is],
                                             moments.vth[:,:,is], moments.qpar[:,:,is], z, r, dt, spectral)
        end
        if composition.n_neutral_species > 0 && abs(CX_frequency) > 0.0
            @views source_terms_evolve_ppar_CX!(pdf_out[:,:,:,:], fvec_in.pdf[:,:,:,:],
                                                fvec_in.density, fvec_in.ppar, composition,
                                                CX_frequency, dt, z, r)
        end
    elseif moments.evolve_density
        @s_r_z_loop_s is begin
            @views source_terms_evolve_density!(pdf_out[:,:,:,is], fvec_in.pdf[:,:,:,is],
                                                fvec_in.density[:,:,is], fvec_in.upar[:,:,is], z, r, dt, spectral)
        end
    end
    return nothing
end
function source_terms_evolve_density!(pdf_out, pdf_in, dens, upar, z, r, dt, spectral)
    # update the density
    nvpa = size(pdf_out, 1)
    @s_r_z_loop_r ir begin
        # calculate d(n*upar)/dz
        @. z.scratch = dens[:,ir]*upar[:,ir]
        derivative!(z.scratch, z.scratch, z, spectral)
        @. z.scratch *= dt/dens[:,ir]
        #derivative!(z.scratch, z.scratch, z, -upar, spectral)
        @s_r_z_loop_z iz begin
            for ivpa ∈ 1:nvpa
                pdf_out[ivpa,iz,ir] += pdf_in[ivpa,iz,ir]*z.scratch[iz]
            end
        end
    end
    return nothing
end
function source_terms_evolve_ppar!(pdf_out, pdf_in, dens, upar, ppar, vth, qpar, z, r, dt, spectral)
    nvpa = size(pdf_out, 1)
    @s_r_z_loop_r ir begin
        # calculate dn/dz
        derivative!(z.scratch, view(dens,:,ir), z, spectral)
        # update the pdf to account for the density gradient contribution to the source
        @. z.scratch *= dt*upar[:,ir]/dens[:,ir]
        # calculate dvth/dz
        derivative!(z.scratch2, view(vth,:,ir), z, spectral)
        # update the pdf to account for the -g*upar/vth * dvth/dz contribution to the source
        @. z.scratch -= dt*z.scratch2*upar[:,ir]/vth[:,ir]
        # calculate dqpar/dz
        derivative!(z.scratch2, view(qpar,:,ir), z, spectral)
        # update the pdf to account for the parallel heat flux contribution to the source
        @. z.scratch -= 0.5*dt*z.scratch2/ppar[:,ir]

        @s_r_z_loop_z iz begin
            for ivpa ∈ 1:nvpa
                pdf_out[ivpa,iz,ir] += pdf_in[ivpa,iz,ir]*z.scratch[iz]
            end
        end
    end
    return nothing
end
function source_terms_evolve_ppar_CX!(pdf_out, pdf_in, dens, ppar, composition, CX_frequency, dt, z, r)
    @s_r_z_loop_s is begin
        if is ∈ composition.ion_species_range
            for isp ∈ composition.neutral_species_range
                @s_r_z_loop_r ir begin
                    @s_r_z_loop_z iz begin
                        @views @. pdf_out[:,iz,ir,is] -= 0.5*dt*pdf_in[:,iz,ir,is]*CX_frequency *
                        (dens[iz,ir,isp]*ppar[iz,ir,is]-dens[iz,ir,is]*ppar[iz,ir,isp])/ppar[iz,ir,is]
                    end
                end
            end
        end
        if is ∈ composition.neutral_species_range
            for isp ∈ composition.ion_species_range
                @s_r_z_loop_r ir begin
                    @s_r_z_loop_z iz begin
                        @views @. pdf_out[:,iz,ir,is] -= 0.5*dt*pdf_in[:,iz,ir,is]*CX_frequency *
                        (dens[iz,ir,isp]*ppar[iz,ir,is]-dens[iz,ir,is]*ppar[iz,ir,isp])/ppar[iz,ir,is]
                    end
                end
            end
        end
    end
    return nothing
end

end

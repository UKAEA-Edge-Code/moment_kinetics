export run_assembly_test
using Printf
using Plots
using LaTeXStrings
using MPI
using Measures
using Dates
import moment_kinetics
using moment_kinetics.array_allocation: allocate_float, allocate_shared_float
using moment_kinetics.input_structs: grid_input, advection_input
using moment_kinetics.coordinates: define_coordinate
using moment_kinetics.chebyshev: setup_chebyshev_pseudospectral
using moment_kinetics.gauss_legendre: setup_gausslegendre_pseudospectral, get_QQ_local!
using moment_kinetics.type_definitions: mk_float, mk_int
using moment_kinetics.fokker_planck: init_fokker_planck_collisions 
using moment_kinetics.fokker_planck: init_fokker_planck_collisions_weak_form
using moment_kinetics.fokker_planck: fokker_planck_collision_operator_weak_form!
using moment_kinetics.fokker_planck: conserving_corrections!
using moment_kinetics.calculus: derivative!
using moment_kinetics.velocity_moments: get_density, get_upar, get_ppar, get_pperp, get_pressure
using moment_kinetics.communication
using moment_kinetics.communication: MPISharedArray
using moment_kinetics.looping
using SparseArrays: sparse
using LinearAlgebra: mul!, lu, cholesky

using moment_kinetics.fokker_planck_test: F_Maxwellian, G_Maxwellian, H_Maxwellian
using moment_kinetics.fokker_planck_test: d2Gdvpa2_Maxwellian, d2Gdvperp2_Maxwellian, d2Gdvperpdvpa_Maxwellian, dGdvperp_Maxwellian
using moment_kinetics.fokker_planck_test: dHdvperp_Maxwellian, dHdvpa_Maxwellian
using moment_kinetics.fokker_planck_test: Cssp_Maxwellian_inputs

using moment_kinetics.fokker_planck_calculus: elliptic_solve!, ravel_c_to_vpavperp!, ravel_vpavperp_to_c!, ravel_c_to_vpavperp_parallel!
using moment_kinetics.fokker_planck_calculus: enforce_zero_bc!, allocate_rosenbluth_potential_boundary_data
using moment_kinetics.fokker_planck_calculus: calculate_rosenbluth_potential_boundary_data!, calculate_rosenbluth_potential_boundary_data_exact!
using moment_kinetics.fokker_planck_calculus: test_rosenbluth_potential_boundary_data, enforce_vpavperp_BCs!



    
    function print_matrix(matrix,name::String,n::mk_int,m::mk_int)
        println("\n ",name," \n")
        for i in 1:n
            for j in 1:m
                @printf("%.2f ", matrix[i,j])
            end
            println("")
        end
        println("\n")
    end
    
    function print_vector(vector,name::String,m::mk_int)
        println("\n ",name," \n")
        for j in 1:m
            @printf("%.3f ", vector[j])
        end
        println("")
        println("\n")
    end 

    function plot_test_data(func_exact,func_num,func_err,func_name,vpa,vperp)
        @views heatmap(vperp.grid, vpa.grid, func_num[:,:], ylabel=L"v_{\|\|}", xlabel=L"v_{\perp}", c = :deep, interpolation = :cubic,
                    windowsize = (360,240), margin = 15pt)
                    outfile = string(func_name*"_num.pdf")
                    savefig(outfile)
        @views heatmap(vperp.grid, vpa.grid, func_exact[:,:], ylabel=L"v_{\|\|}", xlabel=L"v_{\perp}", c = :deep, interpolation = :cubic,
                    windowsize = (360,240), margin = 15pt)
                    outfile = string(func_name*"_exact.pdf")
                    savefig(outfile)
        @views heatmap(vperp.grid, vpa.grid, func_err[:,:], ylabel=L"v_{\|\|}", xlabel=L"v_{\perp}", c = :deep, interpolation = :cubic,
                    windowsize = (360,240), margin = 15pt)
                    outfile = string(func_name*"_err.pdf")
                    savefig(outfile)
        return nothing
    end

    function print_test_data(func_exact,func_num,func_err,func_name)
        @. func_err = abs(func_num - func_exact)
        max_err = maximum(func_err)
        println("maximum("*func_name*"_err): ",max_err)
        return max_err
    end
    
    function print_test_data(func_exact,func_num,func_err,func_name,vpa,vperp,dummy)
        @. func_err = abs(func_num - func_exact)
        max_err = maximum(func_err)
        @. dummy = func_err^2
        # compute the numerator
        num = get_density(dummy,vpa,vperp)
        # compute the denominator
        @. dummy = 1.0
        denom = get_density(dummy,vpa,vperp)
        L2norm = sqrt(num/denom)
        println("maximum("*func_name*"_err): ",max_err," L2("*func_name*"_err): ",L2norm)
        return max_err, L2norm
    end
    
    mutable struct error_data
        max::mk_float
        L2::mk_float
    end
    
    mutable struct moments_error_data
        delta_density::mk_float
        delta_upar::mk_float
        delta_pressure::mk_float
    end
    
    struct fkpl_error_data
        C_M::error_data
        H_M::error_data
        dHdvpa_M::error_data
        dHdvperp_M::error_data
        G_M::error_data
        dGdvperp_M::error_data
        d2Gdvpa2_M::error_data
        d2Gdvperpdvpa_M::error_data
        d2Gdvperp2_M::error_data
        moments::moments_error_data
    end
    
    function allocate_error_data()
        C_M = error_data(0.0,0.0)
        H_M = error_data(0.0,0.0)
        dHdvpa_M = error_data(0.0,0.0)
        dHdvperp_M = error_data(0.0,0.0)
        G_M = error_data(0.0,0.0)
        dGdvperp_M = error_data(0.0,0.0)
        d2Gdvpa2_M = error_data(0.0,0.0)
        d2Gdvperpdvpa_M = error_data(0.0,0.0)
        d2Gdvperp2_M = error_data(0.0,0.0)
        moments = moments_error_data(0.0,0.0,0.0)
        return fkpl_error_data(C_M,H_M,dHdvpa_M,dHdvperp_M,
            G_M,dGdvperp_M,d2Gdvpa2_M,d2Gdvperpdvpa_M,d2Gdvperp2_M,
            moments)
    end
    
    
    function test_weak_form_collisions(ngrid,nelement_vpa,nelement_vperp;
        Lvpa=12.0,Lvperp=6.0,plot_test_output=false,impose_zero_gradient_BC=false,
        test_parallelism=false,test_self_operator=true,
        test_dense_construction=false,standalone=false,
        use_Maxwellian_Rosenbluth_coefficients=false,
        use_Maxwellian_field_particle_distribution=false,
        test_numerical_conserving_terms=false,
        algebraic_solve_for_d2Gdvperp2=true)
        # define inputs needed for the test
        #plot_test_output = false#true
        #impose_zero_gradient_BC = false#true
        #test_parallelism = false#true
        #test_self_operator = true
        #test_dense_construction = false#true
        #ngrid = 3 #number of points per element 
        nelement_local_vpa = nelement_vpa # number of elements per rank
        nelement_global_vpa = nelement_local_vpa # total number of elements 
        nelement_local_vperp = nelement_vperp # number of elements per rank
        nelement_global_vperp = nelement_local_vperp # total number of elements 
        #Lvpa = 12.0 #physical box size in reference units 
        #Lvperp = 6.0 #physical box size in reference units 
        bc = "" #not required to take a particular value, not used 
        # fd_option and adv_input not actually used so given values unimportant
        #discretization = "chebyshev_pseudospectral"
        discretization = "gausslegendre_pseudospectral"
        fd_option = "fourth_order_centered"
        cheb_option = "matrix"
        adv_input = advection_input("default", 1.0, 0.0, 0.0)
        nrank = 1
        irank = 0
        comm = MPI.COMM_NULL
        # create the 'input' struct containing input info needed to create a
        # coordinate
        element_spacing_option = "uniform"
        vpa_input = grid_input("vpa", ngrid, nelement_global_vpa, nelement_local_vpa, 
            nrank, irank, Lvpa, discretization, fd_option, cheb_option, bc, adv_input,comm,element_spacing_option)
        vperp_input = grid_input("vperp", ngrid, nelement_global_vperp, nelement_local_vperp, 
            nrank, irank, Lvperp, discretization, fd_option, cheb_option, bc, adv_input,comm,element_spacing_option)
        # create the coordinate struct 'x'
        println("made inputs")
        println("vpa: ngrid: ",ngrid," nelement: ",nelement_local_vpa, " Lvpa: ",Lvpa)
        println("vperp: ngrid: ",ngrid," nelement: ",nelement_local_vperp, " Lvperp: ",Lvperp)
        vpa, vpa_spectral = define_coordinate(vpa_input)
        vperp, vperp_spectral = define_coordinate(vperp_input)
        
        # Set up MPI
        if standalone
            initialize_comms!()
        end
        setup_distributed_memory_MPI(1,1,1,1)
        looping.setup_loop_ranges!(block_rank[], block_size[];
                                       s=1, sn=1,
                                       r=1, z=1, vperp=vperp.n, vpa=vpa.n,
                                       vzeta=1, vr=1, vz=1)
        nc_global = vpa.n*vperp.n
        begin_serial_region()
        start_init_time = now()
        
        fkpl_arrays = init_fokker_planck_collisions_weak_form(vpa,vperp,vpa_spectral,vperp_spectral; 
                           precompute_weights=true, test_dense_matrix_construction=test_dense_construction)
        KKpar2D_with_BC_terms_sparse = fkpl_arrays.KKpar2D_with_BC_terms_sparse
        KKperp2D_with_BC_terms_sparse = fkpl_arrays.KKperp2D_with_BC_terms_sparse
        lu_obj_MM = fkpl_arrays.lu_obj_MM
        lu_obj_MMZG = fkpl_arrays.lu_obj_MMZG
        finish_init_time = now()
        
        fvpavperp = Array{mk_float,2}(undef,vpa.n,vperp.n)
        fvpavperp_test = Array{mk_float,2}(undef,vpa.n,vperp.n)
        fvpavperp_err = Array{mk_float,2}(undef,vpa.n,vperp.n)
        d2fvpavperp_dvpa2_exact = Array{mk_float,2}(undef,vpa.n,vperp.n)
        d2fvpavperp_dvpa2_err = Array{mk_float,2}(undef,vpa.n,vperp.n)
        d2fvpavperp_dvpa2_num = Array{mk_float,2}(undef,vpa.n,vperp.n)
        d2fvpavperp_dvperp2_exact = Array{mk_float,2}(undef,vpa.n,vperp.n)
        d2fvpavperp_dvperp2_err = Array{mk_float,2}(undef,vpa.n,vperp.n)
        d2fvpavperp_dvperp2_num = Array{mk_float,2}(undef,vpa.n,vperp.n)
        fc = Array{mk_float,1}(undef,nc_global)
        dfc = Array{mk_float,1}(undef,nc_global)
        gc = Array{mk_float,1}(undef,nc_global)
        dgc = Array{mk_float,1}(undef,nc_global)
        for ivperp in 1:vperp.n
            for ivpa in 1:vpa.n
                fvpavperp[ivpa,ivperp] = exp(-vpa.grid[ivpa]^2 - vperp.grid[ivperp]^2)
                d2fvpavperp_dvpa2_exact[ivpa,ivperp] = (4.0*vpa.grid[ivpa]^2 - 2.0)*exp(-vpa.grid[ivpa]^2 - vperp.grid[ivperp]^2)
                d2fvpavperp_dvperp2_exact[ivpa,ivperp] = (4.0*vperp.grid[ivperp]^2 - 2.0)*exp(-vpa.grid[ivpa]^2 - vperp.grid[ivperp]^2)
            end
        end
        
        # fill fc with fvpavperp
        ravel_vpavperp_to_c!(fc,fvpavperp,vpa.n,vperp.n)
        ravel_c_to_vpavperp!(fvpavperp_test,fc,nc_global,vpa.n)
        @. fvpavperp_err = abs(fvpavperp - fvpavperp_test)
        @serial_region begin
            println("max(ravel_err)",maximum(fvpavperp_err))
        end
        #print_vector(fc,"fc",nc_global)
        # multiply by KKpar2D and fill dfc
        mul!(dfc,KKpar2D_with_BC_terms_sparse,fc)
        mul!(dgc,KKperp2D_with_BC_terms_sparse,fc)
        if impose_zero_gradient_BC
            # enforce zero bc  
            enforce_zero_bc!(fc,vpa,vperp,impose_BC_at_zero_vperp=true)
            enforce_zero_bc!(gc,vpa,vperp,impose_BC_at_zero_vperp=true)
            # invert mass matrix and fill fc
            fc = lu_obj_MMZG \ dfc
            gc = lu_obj_MMZG \ dgc
        else
            # enforce zero bc  
            #enforce_zero_bc!(fc,vpa,vperp,impose_BC_at_zero_vperp=false)
            #enforce_zero_bc!(gc,vpa,vperp,impose_BC_at_zero_vperp=false)
            # invert mass matrix and fill fc
            fc = lu_obj_MM \ dfc
            gc = lu_obj_MM \ dgc
        end
        #fc = cholesky_obj \ dfc
        #print_vector(fc,"fc",nc_global)
        # unravel
        ravel_c_to_vpavperp!(d2fvpavperp_dvpa2_num,fc,nc_global,vpa.n)
        ravel_c_to_vpavperp!(d2fvpavperp_dvperp2_num,gc,nc_global,vpa.n)
        @serial_region begin 
            if nc_global < 30
                print_matrix(d2fvpavperp_dvpa2_num,"d2fvpavperp_dvpa2_num",vpa.n,vperp.n)
            end
            @. d2fvpavperp_dvpa2_err = abs(d2fvpavperp_dvpa2_num - d2fvpavperp_dvpa2_exact)
            println("maximum(d2fvpavperp_dvpa2_err): ",maximum(d2fvpavperp_dvpa2_err))
            @. d2fvpavperp_dvperp2_err = abs(d2fvpavperp_dvperp2_num - d2fvpavperp_dvperp2_exact)
            println("maximum(d2fvpavperp_dvperp2_err): ",maximum(d2fvpavperp_dvperp2_err))
            if nc_global < 30
                print_matrix(d2fvpavperp_dvpa2_err,"d2fvpavperp_dvpa2_err",vpa.n,vperp.n)
            end
            if plot_test_output
                plot_test_data(d2fvpavperp_dvpa2_exact,d2fvpavperp_dvpa2_num,d2fvpavperp_dvpa2_err,"d2fvpavperp_dvpa2",vpa,vperp)
                plot_test_data(d2fvpavperp_dvperp2_exact,d2fvpavperp_dvperp2_num,d2fvpavperp_dvperp2_err,"d2fvpavperp_dvperp2",vpa,vperp)
            end
        end
        # test the Laplacian solve with a standard F_Maxwellian -> H_Maxwellian test
        dummy_vpavperp = Array{mk_float,2}(undef,vpa.n,vperp.n)
        Fs_M = Array{mk_float,2}(undef,vpa.n,vperp.n)
        F_M = Array{mk_float,2}(undef,vpa.n,vperp.n)
        C_M_num = allocate_shared_float(vpa.n,vperp.n)
        C_M_exact = Array{mk_float,2}(undef,vpa.n,vperp.n)
        C_M_err = Array{mk_float,2}(undef,vpa.n,vperp.n)
        #dFdvpa_M = Array{mk_float,2}(undef,vpa.n,vperp.n)
        #dFdvperp_M = Array{mk_float,2}(undef,vpa.n,vperp.n)
        #d2Fdvperpdvpa_M = Array{mk_float,2}(undef,vpa.n,vperp.n)
        H_M_exact = Array{mk_float,2}(undef,vpa.n,vperp.n)
        H_M_num = allocate_shared_float(vpa.n,vperp.n)
        H_M_err = Array{mk_float,2}(undef,vpa.n,vperp.n)
        G_M_exact = Array{mk_float,2}(undef,vpa.n,vperp.n)
        G_M_num = allocate_shared_float(vpa.n,vperp.n)
        G_M_err = Array{mk_float,2}(undef,vpa.n,vperp.n)
        d2Gdvpa2_M_exact = Array{mk_float,2}(undef,vpa.n,vperp.n)
        d2Gdvpa2_M_num = allocate_shared_float(vpa.n,vperp.n)
        d2Gdvpa2_M_err = Array{mk_float,2}(undef,vpa.n,vperp.n)
        d2Gdvperp2_M_exact = Array{mk_float,2}(undef,vpa.n,vperp.n)
        d2Gdvperp2_M_num = allocate_shared_float(vpa.n,vperp.n)
        d2Gdvperp2_M_err = Array{mk_float,2}(undef,vpa.n,vperp.n)
        dGdvperp_M_exact = Array{mk_float,2}(undef,vpa.n,vperp.n)
        dGdvperp_M_num = allocate_shared_float(vpa.n,vperp.n)
        dGdvperp_M_err = Array{mk_float,2}(undef,vpa.n,vperp.n)
        d2Gdvperpdvpa_M_exact = Array{mk_float,2}(undef,vpa.n,vperp.n)
        d2Gdvperpdvpa_M_num = allocate_shared_float(vpa.n,vperp.n)
        d2Gdvperpdvpa_M_err = Array{mk_float,2}(undef,vpa.n,vperp.n)
        dHdvpa_M_exact = Array{mk_float,2}(undef,vpa.n,vperp.n)
        dHdvpa_M_num = allocate_shared_float(vpa.n,vperp.n)
        dHdvpa_M_err = Array{mk_float,2}(undef,vpa.n,vperp.n)
        dHdvperp_M_exact = Array{mk_float,2}(undef,vpa.n,vperp.n)
        dHdvperp_M_num = allocate_shared_float(vpa.n,vperp.n)
        dHdvperp_M_err = Array{mk_float,2}(undef,vpa.n,vperp.n)

        if test_self_operator
            dens, upar, vth = 1.0, 1.0, 1.0
            denss, upars, vths = dens, upar, vth
        else
            denss, upars, vths = 1.0, -1.0, 2.0/3.0
            dens, upar, vth = 1.0, 1.0, 1.0
        end
        ms = 1.0
        msp = 1.0
        nussp = 1.0
        begin_serial_region()
        for ivperp in 1:vperp.n
            for ivpa in 1:vpa.n
                Fs_M[ivpa,ivperp] = F_Maxwellian(denss,upars,vths,vpa,vperp,ivpa,ivperp)
                F_M[ivpa,ivperp] = F_Maxwellian(dens,upar,vth,vpa,vperp,ivpa,ivperp)
                H_M_exact[ivpa,ivperp] = H_Maxwellian(dens,upar,vth,vpa,vperp,ivpa,ivperp)
                G_M_exact[ivpa,ivperp] = G_Maxwellian(dens,upar,vth,vpa,vperp,ivpa,ivperp)
                d2Gdvpa2_M_exact[ivpa,ivperp] = d2Gdvpa2_Maxwellian(dens,upar,vth,vpa,vperp,ivpa,ivperp)
                d2Gdvperp2_M_exact[ivpa,ivperp] = d2Gdvperp2_Maxwellian(dens,upar,vth,vpa,vperp,ivpa,ivperp)
                dGdvperp_M_exact[ivpa,ivperp] = dGdvperp_Maxwellian(dens,upar,vth,vpa,vperp,ivpa,ivperp)
                d2Gdvperpdvpa_M_exact[ivpa,ivperp] = d2Gdvperpdvpa_Maxwellian(dens,upar,vth,vpa,vperp,ivpa,ivperp)
                dHdvpa_M_exact[ivpa,ivperp] = dHdvpa_Maxwellian(dens,upar,vth,vpa,vperp,ivpa,ivperp)
                dHdvperp_M_exact[ivpa,ivperp] = dHdvperp_Maxwellian(dens,upar,vth,vpa,vperp,ivpa,ivperp)
                C_M_exact[ivpa,ivperp] = Cssp_Maxwellian_inputs(denss,upars,vths,ms,
                                                                dens,upar,vth,msp,
                                                                nussp,vpa,vperp,ivpa,ivperp)
            end
        end
        rpbd_exact = allocate_rosenbluth_potential_boundary_data(vpa,vperp)
        # use known test function to provide exact data
        calculate_rosenbluth_potential_boundary_data_exact!(rpbd_exact,
              H_M_exact,dHdvpa_M_exact,dHdvperp_M_exact,G_M_exact,
              dGdvperp_M_exact,d2Gdvperp2_M_exact,
              d2Gdvperpdvpa_M_exact,d2Gdvpa2_M_exact,vpa,vperp)
        @serial_region begin
            println("begin C calculation   ", Dates.format(now(), dateformat"H:MM:SS"))
        end

        fokker_planck_collision_operator_weak_form!(Fs_M,F_M,ms,msp,nussp,
                                             fkpl_arrays,
                                             vperp, vpa, vperp_spectral, vpa_spectral,
                                             test_assembly_serial=test_parallelism,
                                             impose_zero_gradient_BC=impose_zero_gradient_BC,
                                             use_Maxwellian_Rosenbluth_coefficients=use_Maxwellian_Rosenbluth_coefficients,
                                             use_Maxwellian_field_particle_distribution=use_Maxwellian_field_particle_distribution,
                                             algebraic_solve_for_d2Gdvperp2=algebraic_solve_for_d2Gdvperp2)
        if test_numerical_conserving_terms && test_self_operator
            # enforce the boundary conditions on CC before it is used for timestepping
            enforce_vpavperp_BCs!(fkpl_arrays.CC,vpa,vperp,vpa_spectral,vperp_spectral)
            # make ad-hoc conserving corrections
            conserving_corrections!(fkpl_arrays.CC,Fs_M,vpa,vperp,dummy_vpavperp)            
        end
        # extract C[Fs,Fs'] result
        # and Rosenbluth potentials for testing
        begin_vperp_vpa_region()
        @loop_vperp_vpa ivperp ivpa begin
            C_M_num[ivpa,ivperp] = fkpl_arrays.CC[ivpa,ivperp]
            H_M_num[ivpa,ivperp] = fkpl_arrays.HH[ivpa,ivperp]
            dHdvpa_M_num[ivpa,ivperp] = fkpl_arrays.dHdvpa[ivpa,ivperp]
            dHdvperp_M_num[ivpa,ivperp] = fkpl_arrays.dHdvperp[ivpa,ivperp]
            dGdvperp_M_num[ivpa,ivperp] = fkpl_arrays.dGdvperp[ivpa,ivperp]
            d2Gdvperp2_M_num[ivpa,ivperp] = fkpl_arrays.d2Gdvperp2[ivpa,ivperp]
            d2Gdvpa2_M_num[ivpa,ivperp] = fkpl_arrays.d2Gdvpa2[ivpa,ivperp]
            d2Gdvperpdvpa_M_num[ivpa,ivperp] = fkpl_arrays.d2Gdvperpdvpa[ivpa,ivperp]
        end
        
        S_dummy = fkpl_arrays.S_dummy
        begin_vperp_vpa_region()
        @loop_vperp_vpa ivperp ivpa begin
            S_dummy[ivpa,ivperp] = 2.0*H_M_num[ivpa,ivperp]
        end
        # solve for G as an added test bonus
        elliptic_solve!(G_M_num,S_dummy,fkpl_arrays.rpbd.G_data,
                fkpl_arrays.lu_obj_LP,fkpl_arrays.MM2D_sparse,fkpl_arrays.rhsc,
                fkpl_arrays.sc,vpa,vperp)
      
        init_time = Dates.value(finish_init_time - start_init_time)
        calculate_time = Dates.value(now() - finish_init_time)
        begin_serial_region()
        fkerr = allocate_error_data()
        @serial_region begin
            println("finished C calculation   ", Dates.format(now(), dateformat"H:MM:SS"))
            
            # test the boundary data calculation
            if !use_Maxwellian_Rosenbluth_coefficients
                test_rosenbluth_potential_boundary_data(fkpl_arrays.rpbd,rpbd_exact,vpa,vperp)
            end
            dummy_array = Array{mk_float,2}(undef,vpa.n,vperp.n)
            fkerr.H_M.max, fkerr.H_M.L2 = print_test_data(H_M_exact,H_M_num,H_M_err,"H_M",vpa,vperp,dummy_array)
            fkerr.dHdvpa_M.max, fkerr.dHdvpa_M.L2 = print_test_data(dHdvpa_M_exact,dHdvpa_M_num,dHdvpa_M_err,"dHdvpa_M",vpa,vperp,dummy_array)
            fkerr.dHdvperp_M.max, fkerr.dHdvperp_M.L2 = print_test_data(dHdvperp_M_exact,dHdvperp_M_num,dHdvperp_M_err,"dHdvperp_M",vpa,vperp,dummy_array)
            fkerr.G_M.max, fkerr.G_M.L2 = print_test_data(G_M_exact,G_M_num,G_M_err,"G_M",vpa,vperp,dummy_array)
            fkerr.d2Gdvpa2_M.max, fkerr.d2Gdvpa2_M.L2 = print_test_data(d2Gdvpa2_M_exact,d2Gdvpa2_M_num,d2Gdvpa2_M_err,"d2Gdvpa2_M",vpa,vperp,dummy_array)
            fkerr.dGdvperp_M.max, fkerr.dGdvperp_M.L2 = print_test_data(dGdvperp_M_exact,dGdvperp_M_num,dGdvperp_M_err,"dGdvperp_M",vpa,vperp,dummy_array)
            fkerr.d2Gdvperpdvpa_M.max, fkerr.d2Gdvperpdvpa_M.L2 = print_test_data(d2Gdvperpdvpa_M_exact,d2Gdvperpdvpa_M_num,d2Gdvperpdvpa_M_err,"d2Gdvperpdvpa_M",vpa,vperp,dummy_array)
            fkerr.d2Gdvperp2_M.max, fkerr.d2Gdvperp2_M.L2 = print_test_data(d2Gdvperp2_M_exact,d2Gdvperp2_M_num,d2Gdvperp2_M_err,"d2Gdvperp2_M",vpa,vperp,dummy_array)
            fkerr.C_M.max, fkerr.C_M.L2 = print_test_data(C_M_exact,C_M_num,C_M_err,"C_M",vpa,vperp,dummy_array)
            
            # calculate the entropy production
            lnfC = fkpl_arrays.rhsvpavperp
            @loop_vperp_vpa ivperp ivpa begin
                lnfC[ivpa,ivperp] = Fs_M[ivpa,ivperp]*C_M_num[ivpa,ivperp]
            end
            dSdt = - get_density(lnfC,vpa,vperp)
            println("dSdt: $dSdt should be >0.0")
            if plot_test_output
                plot_test_data(C_M_exact,C_M_num,C_M_err,"C_M",vpa,vperp)
                plot_test_data(H_M_exact,H_M_num,H_M_err,"H_M",vpa,vperp)
                plot_test_data(dHdvpa_M_exact,dHdvpa_M_num,dHdvpa_M_err,"dHdvpa_M",vpa,vperp)
                plot_test_data(dHdvperp_M_exact,dHdvperp_M_num,dHdvperp_M_err,"dHdvperp_M",vpa,vperp)
                plot_test_data(G_M_exact,G_M_num,G_M_err,"G_M",vpa,vperp)
                plot_test_data(dGdvperp_M_exact,dGdvperp_M_num,dGdvperp_M_err,"dGdvperp_M",vpa,vperp)
                plot_test_data(d2Gdvperp2_M_exact,d2Gdvperp2_M_num,d2Gdvperp2_M_err,"d2Gdvperp2_M",vpa,vperp)
                plot_test_data(d2Gdvperpdvpa_M_exact,d2Gdvperpdvpa_M_num,d2Gdvperpdvpa_M_err,"d2Gdvperpdvpa_M",vpa,vperp)
                plot_test_data(d2Gdvpa2_M_exact,d2Gdvpa2_M_num,d2Gdvpa2_M_err,"d2Gdvpa2_M",vpa,vperp)
            end
        end
        if test_self_operator
            delta_n = get_density(C_M_num, vpa, vperp)
            delta_upar = get_upar(C_M_num, vpa, vperp, dens)
            delta_ppar = msp*get_ppar(C_M_num, vpa, vperp, upar)
            delta_pperp = msp*get_pperp(C_M_num, vpa, vperp)
            delta_pressure = get_pressure(delta_ppar,delta_pperp)
            @serial_region begin
                println("delta_n: ", delta_n)
                println("delta_upar: ", delta_upar)
                println("delta_pressure: ", delta_pressure)
            end
            fkerr.moments.delta_density = delta_n
            fkerr.moments.delta_upar = delta_upar
            fkerr.moments.delta_pressure = delta_pressure
        else
            delta_n = get_density(C_M_num, vpa, vperp)
            @serial_region begin
                println("delta_n: ", delta_n)
            end
            fkerr.moments.delta_density = delta_n
        end
        if standalone
            finalize_comms!()
        end
        return fkerr, calculate_time, init_time
    end

    function expected_nelement_scaling!(expected,nelement_list,ngrid,nscan)
        for iscan in 1:nscan
            expected[iscan] = (1.0/nelement_list[iscan])^(ngrid - 1)
        end
    end

    function expected_nelement_integral_scaling!(expected,nelement_list,ngrid,nscan)
        for iscan in 1:nscan
            expected[iscan] = (1.0/nelement_list[iscan])^(ngrid+1)
        end
    end

    function expect_timing!(expected,nelement_list,nscan,power)
        for iscan in 1:nscan
            expected[iscan] = nelement_list[iscan]^power
        end
    end
    
    function run_assembly_test(; ngrid=5, nelement_list = [8],
        impose_zero_gradient_BC= false,
        plot_scan=true,
        plot_test_output = false,
        use_Maxwellian_Rosenbluth_coefficients=false,
        use_Maxwellian_field_particle_distribution=false,
        test_dense_construction=false,
        test_parallelism=false,
        test_numerical_conserving_terms=false,
        algebraic_solve_for_d2Gdvperp2=true,
        Lvpa = 12.0, Lvperp = 6.0)
        initialize_comms!()
        #ngrid = 5
        #plot_scan = true
        #plot_test_output = true#false
        #impose_zero_gradient_BC = false
        #test_parallelism = false
        test_self_operator = true
        #test_dense_construction = false
        #nelement_list = Int[8, 16, 32, 64, 128]
        #nelement_list = Int[4, 8, 16, 32, 64]
        #nelement_list = Int[2, 4, 8]
        #nelement_list = Int[4, 8, 16, 32, 64]
        #nelement_list = Int[2, 4, 8, 16, 32]
        #nelement_list = Int[2, 4, 8, 16]
        #nelement_list = Int[100]
        #nelement_list = Int[8]
        #nelement_list = Int[4]
        nscan = size(nelement_list,1)
        max_C_err = Array{mk_float,1}(undef,nscan)
        max_H_err = Array{mk_float,1}(undef,nscan)
        max_G_err = Array{mk_float,1}(undef,nscan)
        max_dHdvpa_err = Array{mk_float,1}(undef,nscan)
        max_dHdvperp_err = Array{mk_float,1}(undef,nscan)
        max_d2Gdvperp2_err = Array{mk_float,1}(undef,nscan)
        max_d2Gdvpa2_err = Array{mk_float,1}(undef,nscan)
        max_d2Gdvperpdvpa_err = Array{mk_float,1}(undef,nscan)
        max_dGdvperp_err = Array{mk_float,1}(undef,nscan)
        L2_C_err = Array{mk_float,1}(undef,nscan)
        L2_H_err = Array{mk_float,1}(undef,nscan)
        L2_G_err = Array{mk_float,1}(undef,nscan)
        L2_dHdvpa_err = Array{mk_float,1}(undef,nscan)
        L2_dHdvperp_err = Array{mk_float,1}(undef,nscan)
        L2_d2Gdvperp2_err = Array{mk_float,1}(undef,nscan)
        L2_d2Gdvpa2_err = Array{mk_float,1}(undef,nscan)
        L2_d2Gdvperpdvpa_err = Array{mk_float,1}(undef,nscan)
        L2_dGdvperp_err = Array{mk_float,1}(undef,nscan)
        #max_d2fsdvpa2_err = Array{mk_float,1}(undef,nscan)
        #max_d2fsdvperp2_err = Array{mk_float,1}(undef,nscan)
        n_err = Array{mk_float,1}(undef,nscan)
        u_err = Array{mk_float,1}(undef,nscan)
        p_err = Array{mk_float,1}(undef,nscan)
        calculate_times = Array{mk_float,1}(undef,nscan)
        init_times = Array{mk_float,1}(undef,nscan)
        
        expected = Array{mk_float,1}(undef,nscan)
        expected_nelement_scaling!(expected,nelement_list,ngrid,nscan)
        expected_integral = Array{mk_float,1}(undef,nscan)
        expected_nelement_integral_scaling!(expected_integral,nelement_list,ngrid,nscan)
        expected_label = L"(1/N_{el})^{n_g - 1}"
        expected_integral_label = L"(1/N_{el})^{n_g +1}"
        
        expected_t_2 = Array{mk_float,1}(undef,nscan)
        expected_t_3 = Array{mk_float,1}(undef,nscan)
        expect_timing!(expected_t_2,nelement_list,nscan,2)
        expect_timing!(expected_t_3,nelement_list,nscan,3)
        expected_t_2_label = L"(N_{element})^2"
        expected_t_3_label = L"(N_{element})^3"
        
        for iscan in 1:nscan
            local nelement = nelement_list[iscan]
            nelement_vpa = 2*nelement
            nelement_vperp = nelement
            fkerr, calculate_times[iscan], init_times[iscan] = test_weak_form_collisions(ngrid,nelement_vpa,nelement_vperp,
            plot_test_output=plot_test_output,
            impose_zero_gradient_BC=impose_zero_gradient_BC,
            test_parallelism=test_parallelism,
            test_self_operator=test_self_operator,
            test_dense_construction=test_dense_construction,
            use_Maxwellian_Rosenbluth_coefficients=use_Maxwellian_Rosenbluth_coefficients,
            use_Maxwellian_field_particle_distribution=use_Maxwellian_field_particle_distribution,
            test_numerical_conserving_terms=test_numerical_conserving_terms,
            algebraic_solve_for_d2Gdvperp2=algebraic_solve_for_d2Gdvperp2,
            standalone=false, Lvpa=Lvpa, Lvperp=Lvperp)
            max_C_err[iscan], L2_C_err[iscan] = fkerr.C_M.max ,fkerr.C_M.L2
            max_H_err[iscan], L2_H_err[iscan] = fkerr.H_M.max ,fkerr.H_M.L2
            max_dHdvpa_err[iscan], L2_dHdvpa_err[iscan] = fkerr.dHdvpa_M.max ,fkerr.dHdvpa_M.L2
            max_dHdvperp_err[iscan], L2_dHdvperp_err[iscan] = fkerr.dHdvperp_M.max ,fkerr.dHdvperp_M.L2
            max_G_err[iscan], L2_G_err[iscan] = fkerr.G_M.max ,fkerr.G_M.L2
            max_dGdvperp_err[iscan], L2_dGdvperp_err[iscan] = fkerr.dGdvperp_M.max ,fkerr.dGdvperp_M.L2
            max_d2Gdvpa2_err[iscan], L2_d2Gdvpa2_err[iscan] = fkerr.d2Gdvpa2_M.max ,fkerr.d2Gdvpa2_M.L2
            max_d2Gdvperpdvpa_err[iscan], L2_d2Gdvperpdvpa_err[iscan] = fkerr.d2Gdvperpdvpa_M.max ,fkerr.d2Gdvperpdvpa_M.L2
            max_d2Gdvperp2_err[iscan], L2_d2Gdvperp2_err[iscan] = fkerr.d2Gdvperp2_M.max ,fkerr.d2Gdvperp2_M.L2
            n_err[iscan] = abs(fkerr.moments.delta_density)
            u_err[iscan] = abs(fkerr.moments.delta_upar)
            p_err[iscan] = abs(fkerr.moments.delta_pressure)
        end
        if global_rank[]==0 && plot_scan
            fontsize = 8
            #ytick_sequence = Array([1.0e-13,1.0e-12,1.0e-11,1.0e-10,1.0e-9,1.0e-8,1.0e-7,1.0e-6,1.0e-5,1.0e-4,1.0e-3,1.0e-2,1.0e-1,1.0e-0,1.0e1])
            ytick_sequence = Array([1.0e-12,1.0e-11,1.0e-10,1.0e-9,1.0e-8,1.0e-7,1.0e-6,1.0e-5,1.0e-4,1.0e-3,1.0e-2,1.0e-1])
            xlabel = L"N_{element}"
            Clabel = L"\epsilon_{\infty}(C)"
            Hlabel = L"\epsilon_{\infty}(H)"
            Glabel = L"\epsilon_{\infty}(G)"
            dHdvpalabel = L"\epsilon_{\infty}(dH/d v_{\|\|})"
            dHdvperplabel = L"\epsilon_{\infty}(dH/d v_{\perp})"
            d2Gdvperp2label = L"\epsilon_{\infty}(d^2G/d v_{\perp}^2)"
            d2Gdvpa2label = L"\epsilon_{\infty}(d^2G/d v_{\|\|}^2)"
            d2Gdvperpdvpalabel = L"\epsilon_{\infty}(d^2G/d v_{\perp} d v_{\|\|})"
            dGdvperplabel = L"\epsilon_{\infty}(dG/d v_{\perp})"
            
            #println(max_G_err,max_H_err,max_dHdvpa_err,max_dHdvperp_err,max_d2Gdvperp2_err,max_d2Gdvpa2_err,max_d2Gdvperpdvpa_err,max_dGdvperp_err, expected, expected_integral)
            plot(nelement_list, [max_C_err,max_H_err,max_G_err, expected, expected_integral],
            xlabel=xlabel, label=[Clabel Hlabel Glabel expected_label expected_integral_label], ylabel="",
             shape =:circle, xscale=:log10, yscale=:log10, xticks = (nelement_list, nelement_list), yticks = (ytick_sequence, ytick_sequence), markersize = 5, linewidth=2, 
              xtickfontsize = fontsize, xguidefontsize = fontsize, ytickfontsize = fontsize, yguidefontsize = fontsize, legendfontsize = fontsize,
              foreground_color_legend = nothing, background_color_legend = nothing, legend=:bottomleft)
            outfile = "fkpl_C_G_H_max_test_ngrid_"*string(ngrid)*"_GLL.pdf"
            savefig(outfile)
            println(outfile)
            println([max_C_err,max_H_err,max_G_err, expected, expected_integral])
            
            plot(nelement_list,  [max_dHdvpa_err, max_dHdvperp_err, max_d2Gdvperp2_err, max_d2Gdvpa2_err, max_d2Gdvperpdvpa_err, max_dGdvperp_err, expected,      expected_integral],
            xlabel=xlabel, label=[dHdvpalabel     dHdvperplabel     d2Gdvperp2label     d2Gdvpa2label     d2Gdvperpdvpalabel     dGdvperplabel     expected_label expected_integral_label], ylabel="",
             shape =:circle, xscale=:log10, yscale=:log10, xticks = (nelement_list, nelement_list), yticks = (ytick_sequence, ytick_sequence), markersize = 5, linewidth=2, 
              xtickfontsize = fontsize, xguidefontsize = fontsize, ytickfontsize = fontsize, yguidefontsize = fontsize, legendfontsize = fontsize,
              foreground_color_legend = nothing, background_color_legend = nothing, legend=:bottomleft)
            outfile = "fkpl_coeffs_max_test_ngrid_"*string(ngrid)*"_GLL.pdf"
            savefig(outfile)
            println(outfile)
            println([max_dHdvpa_err, max_dHdvperp_err, max_d2Gdvperp2_err, max_d2Gdvpa2_err, max_d2Gdvperpdvpa_err, max_dGdvperp_err, expected,      expected_integral])
            
            
            ClabelL2 = L"\epsilon_{L2}(C)"
            HlabelL2 = L"\epsilon_{L2}(H)"
            GlabelL2 = L"\epsilon_{L2}(G)"
            dHdvpalabelL2 = L"\epsilon_{L2}(dH/d v_{\|\|})"
            dHdvperplabelL2 = L"\epsilon_{L2}(dH/d v_{\perp})"
            d2Gdvperp2labelL2 = L"\epsilon_{L2}(d^2G/d v_{\perp}^2)"
            d2Gdvpa2labelL2 = L"\epsilon_{L2}(d^2G/d v_{\|\|}^2)"
            d2GdvperpdvpalabelL2 = L"\epsilon_{L2}(d^2G/d v_{\perp} d v_{\|\|})"
            dGdvperplabelL2 = L"\epsilon_{L2}(dG/d v_{\perp})"
            
            
            plot(nelement_list, [L2_C_err,L2_H_err,L2_G_err, expected, expected_integral],
            xlabel=xlabel, label=[ClabelL2 HlabelL2 GlabelL2 expected_label expected_integral_label], ylabel="",
             shape =:circle, xscale=:log10, yscale=:log10, xticks = (nelement_list, nelement_list), yticks = (ytick_sequence, ytick_sequence), markersize = 5, linewidth=2, 
              xtickfontsize = fontsize, xguidefontsize = fontsize, ytickfontsize = fontsize, yguidefontsize = fontsize, legendfontsize = fontsize,
              foreground_color_legend = nothing, background_color_legend = nothing, legend=:bottomleft)
            outfile = "fkpl_C_G_H_L2_test_ngrid_"*string(ngrid)*"_GLL.pdf"
            savefig(outfile)
            println(outfile)
            println([L2_C_err,L2_H_err,L2_G_err, expected, expected_integral])
            
            plot(nelement_list,  [L2_dHdvpa_err, L2_dHdvperp_err, L2_d2Gdvperp2_err, L2_d2Gdvpa2_err, L2_d2Gdvperpdvpa_err, L2_dGdvperp_err,  expected,      expected_integral],
            xlabel=xlabel, label=[dHdvpalabelL2  dHdvperplabelL2  d2Gdvperp2labelL2  d2Gdvpa2labelL2  d2GdvperpdvpalabelL2  dGdvperplabelL2   expected_label expected_integral_label], ylabel="",
             shape =:circle, xscale=:log10, yscale=:log10, xticks = (nelement_list, nelement_list), yticks = (ytick_sequence, ytick_sequence), markersize = 5, linewidth=2, 
              xtickfontsize = fontsize, xguidefontsize = fontsize, ytickfontsize = fontsize, yguidefontsize = fontsize, legendfontsize = fontsize,
              foreground_color_legend = nothing, background_color_legend = nothing, legend=:bottomleft)
            outfile = "fkpl_coeffs_L2_test_ngrid_"*string(ngrid)*"_GLL.pdf"
            savefig(outfile)
            println(outfile)
            println([L2_dHdvpa_err, L2_dHdvperp_err, L2_d2Gdvperp2_err, L2_d2Gdvpa2_err, L2_d2Gdvperpdvpa_err, L2_dGdvperp_err,  expected,      expected_integral])
            
            nlabel = L"|\Delta n|"
            ulabel = L"|\Delta u_{\|\|}|"
            plabel = L"|\Delta p|"
            
            if test_self_operator
                plot(nelement_list, [max_C_err, L2_C_err, n_err, u_err, p_err, expected, expected_integral],
                xlabel=xlabel, label=[Clabel ClabelL2 nlabel ulabel plabel expected_label expected_integral_label], ylabel="",
                 shape =:circle, xscale=:log10, yscale=:log10, xticks = (nelement_list, nelement_list), yticks = (ytick_sequence, ytick_sequence), markersize = 5, linewidth=2, 
                  xtickfontsize = fontsize, xguidefontsize = fontsize, ytickfontsize = fontsize, yguidefontsize = fontsize, legendfontsize = fontsize,
                  foreground_color_legend = nothing, background_color_legend = nothing, legend=:bottomleft)
                outfile = "fkpl_conservation_test_ngrid_"*string(ngrid)*"_GLL.pdf"
                savefig(outfile)
                println(outfile)
                println([max_C_err, L2_C_err, n_err, u_err, p_err, expected, expected_integral])
            else
                plot(nelement_list, [max_C_err, L2_C_err, n_err, expected, expected_integral],
                xlabel=xlabel, label=[Clabel ClabelL2 nlabel expected_label expected_integral_label], ylabel="",
                 shape =:circle, xscale=:log10, yscale=:log10, xticks = (nelement_list, nelement_list), yticks = (ytick_sequence, ytick_sequence), markersize = 5, linewidth=2, 
                  xtickfontsize = fontsize, xguidefontsize = fontsize, ytickfontsize = fontsize, yguidefontsize = fontsize, legendfontsize = fontsize,
                  foreground_color_legend = nothing, background_color_legend = nothing, legend=:bottomleft)
                outfile = "fkpl_conservation_test_ngrid_"*string(ngrid)*"_GLL.pdf"
                savefig(outfile)
                println(outfile)        
                println([max_C_err, L2_C_err, n_err, expected, expected_integral])
            end
            
            calculate_timeslabel = "time/step (ms)"
            init_timeslabel = "time/init (ms)"
            ytick_sequence_timing = Array([10^2,10^3,10^4,10^5,10^6])
            plot(nelement_list, [calculate_times, init_times, expected_t_2, expected_t_3],
            xlabel=xlabel, label=[calculate_timeslabel init_timeslabel expected_t_2_label expected_t_3_label], ylabel="",
             shape =:circle, xscale=:log10, yscale=:log10, xticks = (nelement_list, nelement_list), markersize = 5, linewidth=2, 
              xtickfontsize = fontsize, xguidefontsize = fontsize, ytickfontsize = fontsize, yguidefontsize = fontsize, legendfontsize = fontsize,
              foreground_color_legend = nothing, background_color_legend = nothing, legend=:topleft)
            outfile = "fkpl_timing_test_ngrid_"*string(ngrid)*"_GLL.pdf"
            savefig(outfile)
            println(outfile)
            println([calculate_times, init_times, expected_t_2, expected_t_3])
        end
        finalize_comms!()
    return nothing
    end

if abspath(PROGRAM_FILE) == @__FILE__
    using Pkg
    Pkg.activate(".")
    
    run_assembly_test()
end

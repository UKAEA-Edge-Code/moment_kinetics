module chebyshev

export update_fcheby!
export update_df_chebyshev!
export chebyshev_derivative!
export setup_chebyshev_pseudospectral
export scaled_chebyshev_grid
export chebyshev_spectral_derivative!
export chebyshev_info

using FFTW
using ..type_definitions: mk_float
using ..array_allocation: allocate_float, allocate_complex
using ..clenshaw_curtis: clenshawcurtisweights
import ..interpolation: interpolate_to_grid_1d

struct chebyshev_info{TForward <: FFTW.cFFTWPlan, TBackward <: AbstractFFTs.ScaledPlan}
    # fext is an array for storing f(z) on the extended domain needed
    # to perform complex-to-complex FFT using the fact that f(theta) is even in theta
    fext::Array{Complex{mk_float},1}
    # Chebyshev spectral coefficients of distribution function f
    # first dimension contains location within element
    # second dimension indicates the element
    f::Array{mk_float,2}
    # Chebyshev spectral coefficients of derivative of f
    df::Array{mk_float,1}
    # plan for the complex-to-complex, in-place, forward Fourier transform on Chebyshev-Gauss-Lobatto grid
    forward::TForward
    # plan for the complex-to-complex, in-place, backward Fourier transform on Chebyshev-Gauss-Lobatto grid
    #backward_transform::FFTW.cFFTWPlan
    backward::TBackward
end
# create arrays needed for explicit Chebyshev pseudospectral treatment
# and create the plans for the forward and backward fast Fourier transforms
function setup_chebyshev_pseudospectral(coord)
    # ngrid_fft is the number of grid points in the extended domain
    # in z = cos(theta).  this is necessary to turn a cosine transform on [0,π]
    # into a complex transform on [0,2π], which is more efficient in FFTW
    ngrid_fft = 2*(coord.ngrid-1)
    # create array for f on extended [0,2π] domain in theta = ArcCos[z]
    fext = allocate_complex(ngrid_fft)
    # create arrays for storing Chebyshev spectral coefficients of f and f'
    fcheby = allocate_float(coord.ngrid, coord.nelement)
    dcheby = allocate_float(coord.ngrid)
    # setup the plans for the forward and backward Fourier transforms
    forward_transform = plan_fft!(fext, flags=FFTW.MEASURE)
    backward_transform = plan_ifft!(fext, flags=FFTW.MEASURE)
    # return a structure containing the information needed to carry out
    # a 1D Chebyshev transform
    return chebyshev_info(fext, fcheby, dcheby, forward_transform, backward_transform)
end
# initialize chebyshev grid scaled to interval [-box_length/2, box_length/2]
function scaled_chebyshev_grid(ngrid, nelement, n, box_length, imin, imax)
    # initialize chebyshev grid defined on [1,-1]
    # with n grid points chosen to facilitate
    # the fast Chebyshev transform (aka the discrete cosine transform)
    # needed to obtain Chebyshev spectral coefficients
    # this grid goes from +1 to -1
    chebyshev_grid = chebyshevpoints(ngrid)
    # create array for the full grid
    grid = allocate_float(n)
    # setup the scale factor by which the Chebyshev grid on [-1,1]
    # is to be multiplied to account for the full domain [-L/2,L/2]
    # and the splitting into nelement elements with ngrid grid points
    scale_factor = 0.5*box_length/nelement
    # account for the fact that the minimum index needed for the chebyshev_grid
    # within each element changes from 1 to 2 in going from the first element
    # to the remaining elements
    k = 1
    @inbounds for j ∈ 1:nelement
        #wgts[imin[j]:imax[j]] .= sqrt.(1.0 .- reverse(chebyshev_grid)[k:ngrid].^2) * scale_factor
        # amount by which to shift the centre of this element from zero
        shift = box_length*((j-0.5)/nelement - 0.5)
        # reverse the order of the original chebyshev_grid (ran from [1,-1])
        # and apply the scale factor and shift
        grid[imin[j]:imax[j]] .= (reverse(chebyshev_grid)[k:ngrid] * scale_factor) .+ shift
        # after first element, increase minimum index for chebyshev_grid to 2
        # to avoid double-counting boundary element
        k = 2
    end
    wgts = clenshaw_curtis_weights(ngrid, nelement, n, imin, imax, scale_factor)
    return grid, wgts
end
function chebyshev_derivative!(df, ff, chebyshev, coord)
    # define local variable nelement for convenience
    nelement = coord.nelement
    # check array bounds
    @boundscheck nelement == size(chebyshev.f,2) || throw(BoundsError(chebyshev.f))
    @boundscheck nelement == size(df,2) && coord.ngrid == size(df,1) || throw(BoundsError(df))
    # note that one must multiply by 2*nelement/L to get derivative
    # in scaled coordinate
    scale_factor = 2*nelement/coord.L
    # variable k will be used to avoid double counting of overlapping point
    # at element boundaries (see below for further explanation)
    k = 0
    # calculate the Chebyshev derivative on each element
    @inbounds for j ∈ 1:nelement
        # imin is the minimum index on the full grid for this (jth) element
        # the 'k' below accounts for the fact that the first element includes
        # both boundary points, while each additional element shares a boundary
        # point with neighboring elements.  the choice was made when defining
        # coord.imin to exclude the lower boundary point in each element other
        # than the first so that no point is double-counted
        imin = coord.imin[j]-k
        # imax is the maximum index on the full grid for this (jth) element
        imax = coord.imax[j]
        @views chebyshev_derivative_single_element!(df[:,j], ff[imin:imax],
            chebyshev.f[:,j], chebyshev.df, chebyshev.fext, chebyshev.forward, coord)
        # and multiply by scaling factor needed to go
        # from Chebyshev z coordinate to actual z
        for i ∈ 1:coord.ngrid
            df[i,j] *= scale_factor
        end
        k = 1
    end
    return nothing
end
function chebyshev_derivative_single_element!(df, ff, cheby_f, cheby_df, cheby_fext, forward, coord)
    # calculate the Chebyshev coefficients of the real-space function ff and return
    # as cheby_f
    chebyshev_forward_transform!(cheby_f, cheby_fext, ff, forward, coord.ngrid)
    # calculate the Chebyshev coefficients of the derivative of ff with respect to coord.grid
    chebyshev_spectral_derivative!(cheby_df, cheby_f)
    # inverse Chebyshev transform to get df/dcoord
    chebyshev_backward_transform!(df, cheby_fext, cheby_df, forward, coord.ngrid)
end
# Chebyshev transform f to get Chebyshev spectral coefficients
function update_fcheby!(cheby, ff, coord)
    k = 0
    # loop over the different elements and perform a Chebyshev transform
    # using the grid within each element
    @inbounds for j ∈ 1:coord.nelement
        # imin is the minimum index on the full grid for this (jth) element
        # the 'k' below accounts for the fact that the first element includes
        # both boundary points, while each additional element shares a boundary
        # point with neighboring elements.  the choice was made when defining
        # coord.imin to exclude the lower boundary point in each element other
        # than the first so that no point is double-counted
        imin = coord.imin[j]-k
        # imax is the maximum index on the full grid for this (jth) element
        imax = coord.imax[j]
        chebyshev_forward_transform!(view(cheby.f,:,j),
            cheby.fext, view(ff,imin:imax), cheby.forward, coord.ngrid)
        k = 1
    end
    return nothing
end
# compute the Chebyshev spectral coefficients of the spatial derivative of f
function update_df_chebyshev!(df, chebyshev, coord)
    ngrid = coord.ngrid
    nelement = coord.nelement
    L = coord.L
    @boundscheck nelement == size(chebyshev.f,2) || throw(BoundsError(chebyshev.f))
    @boundscheck nelement == size(df,2) && ngrid == size(df,1) || throw(BoundsError(df))
    # obtain Chebyshev spectral coefficients of f'[z]
    # note that must multiply by 2/Lz to get derivative
    # in scaled coordinate
    scale_factor = 2*nelement/L
    # scan over elements
    @inbounds for j ∈ 1:nelement
        chebyshev_spectral_derivative!(chebyshev.df,view(chebyshev.f,:,j))
        # inverse Chebyshev transform to get df/dz
        # and multiply by scaling factor needed to go
        # from Chebyshev z coordinate to actual z
        chebyshev_backward_transform!(view(df,:,j), chebyshev.fext, chebyshev.df, chebyshev.forward, coord.ngrid)
        for i ∈ 1:ngrid
            df[i,j] *= scale_factor
        end
    end
    return nothing
end
# use Chebyshev basis to compute the derivative of f
function chebyshev_spectral_derivative!(df,f)
    m = length(f)
    @boundscheck m == length(df) || throw(BoundsError(df))
    @inbounds begin
        df[m] = 0.
        df[m-1] = 2*(m-1)*f[m]
        df[m-2] = 2*(m-2)*f[m-1]
        for i ∈ m-3:-1:2
            df[i] = 2*i*f[i+1] + df[i+2]
        end
        df[1] = f[2] + 0.5*df[3]
    end
end

"""
Interpolation from a regular grid to a 1d grid with arbitrary spacing

Arguments
---------
new_grid : Array{mk_float, 1}
    Grid of points to interpolate `coord` to
f : Array{mk_float}
    Field to be interpolated
coord : coordinate
    `coordinate` struct giving the coordinate along which f varies
chebyshev : chebyshev_info
    struct containing information for Chebyshev transforms

Returns
-------
result : Array
    Array with the values of `f` interpolated to the points in `new_grid`.
"""
function interpolate_to_grid_1d(newgrid, f, coord, chebyshev::chebyshev_info)
    # define local variable nelement for convenience
    nelement = coord.nelement
    # check array bounds
    @boundscheck nelement == size(chebyshev.f,2) || throw(BoundsError(chebyshev.f))

    # Array for output
    result = similar(newgrid)

    n_new = size(newgrid)[1]
    # Find which points belong to which element.
    # kstart[j] contains the index of the first point in newgrid that is within element
    # j, and kstart[nelement+1]=n_new.
    # Assumes points in newgrid are sorted.
    # May not be the most efficient algorithm.
    # check to see if any of the newgrid points are to the left of the first grid point
    startidx = 1
    for j ∈ 1:n_new
        # if the new grid location is outside the bounds of the original grid,
        # extrapolate f assuming f is constant beyond the domain
        if newgrid[j] < coord.grid[1]
            startidx += 1
            result[j] = f[1]
        else
            break
        end
    end

    k = startidx
    kstart = [k]
    #kstart = [1]
    #k = 1
    @inbounds for j ∈ 1:nelement
        while true
            if k == n_new+1 || newgrid[k] > coord.grid[coord.imax[j]]
                push!(kstart, k)
                break
            end

            k += 1

            if k == n_new+1 || newgrid[k] > coord.grid[coord.imax[j]]
                push!(kstart, k)
                break
            end
        end
    end

    # First element includes both boundary points, while all others have only one (to
    # avoid duplication), so calculate the first element outside the loop.
    if kstart[1] < kstart[2]
        result[kstart[1]:kstart[2]-1] =
            chebyshev_interpolate_single_element(newgrid[kstart[1]:kstart[2]-1],
                                                 f[coord.imin[1]:coord.imax[1]],
                                                 1, coord, chebyshev)
    end
    @inbounds for j ∈ 2:nelement
        if kstart[j] < kstart[j+1]
            result[kstart[j]:kstart[j+1]-1] =
                chebyshev_interpolate_single_element(newgrid[kstart[j]:kstart[j+1]-1],
                                                     f[coord.imin[j]-1:coord.imax[j]],
                                                     j, coord, chebyshev)
        end
    end

    if kstart[nelement+1] < n_new + 1
        result[kstart[nelement+1]:end] .= f[end]
    end

    return result
end
function chebyshev_interpolate_single_element(newgrid, f, j, coord, chebyshev)
    # Temporary buffer to store Chebyshev coefficients
    cheby_f = Array{mk_float, 1}(undef, coord.ngrid)

    # Array for the result
    result = similar(newgrid, mk_float)

    # Need to transform newgrid values to a scaled z-coordinate associated with the
    # Chebyshev coefficients to get the interpolated function values. Transform is a
    # shift and scale so that the element coordinate goes from -1 to 1
    imin = j == 1 ? coord.imin[1] : coord.imin[j] - 1
    imax = coord.imax[j]
    shift = 0.5 * (coord.grid[imin] + coord.grid[imax])
    scale = 2.0 / (coord.grid[imax] - coord.grid[imin])

    # Get Chebyshev coefficients
    chebyshev_forward_transform!(cheby_f, chebyshev.fext, f, chebyshev.forward, coord.ngrid)

    for (i, x) ∈ enumerate(newgrid)
        z = scale * (x - shift)
        # Evaluate sum of Chebyshev polynomials at z using recurrence relation
        cheb1 = 1.0
        cheb2 = z
        result[i] = cheby_f[1] * cheb1 + cheby_f[2] * cheb2
        for coef in cheby_f[3:end]
            cheb1, cheb2 = cheb2, 2.0 * z * cheb2 - cheb1
            result[i] += coef * cheb2
        end
    end

    return result
end
# returns wgts array containing the integration weights associated
# with all grid points for Clenshaw-Curtis quadrature
function clenshaw_curtis_weights(ngrid, nelement, n, imin, imax, scale_factor)
    # create array containing the integration weights
    wgts = zeros(n)
    # calculate the modified Chebshev moments of the first kind
    μ = chebyshevmoments(ngrid)
    @inbounds begin
        # calculate the weights within a single element and
        # scale to account for modified domain (not [-1,1])
        wgts[1:ngrid] = clenshawcurtisweights(μ)*scale_factor
        if nelement > 1
            # account for double-counting of points at inner element boundaries
            wgts[ngrid] *= 2
            for j ∈ 2:nelement
                wgts[imin[j]:imax[j]] .= wgts[2:ngrid]
            end
            # remove double-counting of outer element boundary for last element
            wgts[n] *= 0.5
        end
    end
    return wgts
end
# compute and return modified Chebyshev moments of the first kind:
# ∫dx Tᵢ(x) over range [-1,1]
function chebyshevmoments(N)
    μ = zeros(N)
    @inbounds for i = 0:2:N-1
        μ[i+1] = 2/(1-i^2)
    end
    return μ
end
# returns the Chebyshev-Gauss-Lobatto grid points on an n point grid
function chebyshevpoints(n)
    grid = allocate_float(n)
    nfac = 1/(n-1)
    @inbounds begin
        # calculate z = cos(θ) ∈ [1,-1]
        for j ∈ 1:n
            grid[j] = cospi((j-1)*nfac)
        end
    end
    return grid
end
# takes the real function ff on a Chebyshev grid in z (domain [-1, 1]),
# which corresponds to the domain [π, 2π] in variable theta = ArcCos(z).
# interested in functions of form f(z) = sum_n c_n T_n(z)
# using T_n(cos(theta)) = cos(n*theta) and z = cos(theta) gives
# f(z) = sum_n c_n cos(n*theta)
# thus a Chebyshev transform is equivalent to a discrete cosine transform
# doing this directly turns out to be slower than extending the domain
# from [0, 2pi] and using the fact that f(z) must be even (as cosines are all even)
# on this extended domain, can do a standard complex-to-complex fft
# fext is an array used to store f(theta) on the extended grid theta ∈ [0,2π)
# ff is f(theta) on the grid [π,2π]
# the Chebyshev coefficients of ff are calculated and stored in chebyf
# n is the number of grid points on the Chebyshev-Gauss-Lobatto grid
# transform is the plan for the complex-to-complex, in-place fft
function chebyshev_forward_transform!(chebyf, fext, ff, transform, n)
    # ff as input is f(z) on the domain [-1,1]
    # corresponding to f(theta) on the domain [π,2π]
    # must extend f(theta) using even-ness about theta=π onto domain [0,2π]
    @inbounds begin
        # first, fill in values for f on domain θ ∈ [0,π]
        # using even-ness of f about θ = π
        for j ∈ 0:n-1
            fext[n-j] = complex(ff[j+1],0.0)
        end
        # next, fill in values for f on domain θ ∈ (π,2π)
        for j ∈ 1:n-2
            fext[n+j] = fext[n-j]
        end
    end
    # perform the forward, complex-to-complex FFT in-place (cheby.fext is overwritten)
    transform*fext
    # use reality + evenness of f to eliminate unncessary information
    # and obtain Chebyshev spectral coefficients for this element
    # also sort out normalisation
    @inbounds begin
        nm = n-1
        nfac = 1/nm
        for j ∈ 2:nm
            chebyf[j] = real(fext[j])*nfac
        end
        nfac *= 0.5
        chebyf[1] = real(fext[1])*nfac
        chebyf[n] = real(fext[n])*nfac
    end
    return nothing
end

function chebyshev_backward_transform!(ff, fext, chebyf, transform, n)
    # chebyf as input contains Chebyshev spectral coefficients
    # need to use reality condition to extend onto negative frequency domain
    @inbounds begin
        # first, fill in values for fext corresponding to positive frequencies
        for j ∈ 2:n-1
            fext[j] = chebyf[j]*0.5
        end
        # next, fill in values for fext corresponding to negative frequencies
        # using fext(-k) = conjg(fext(k)) = fext(k)
        # usual FFT ordering with j=1 <-> k=0, followed by ascending k up to kmax
        # and then descending from -kmax down to -dk
        for j ∈ 1:n-2
            fext[n+j] = fext[n-j]
        end
        # fill in zero frequency mode, which is special in that it does not require
        # the 1/2 scale factor
        fext[1] = chebyf[1]
        fext[n] = chebyf[n]
    end
    # perform the backward, complex-to-complex FFT in-place (fext is overwritten)
    transform*fext
    # fext now contains a real function on θ [0,2π)
    # all we need is the real(fext) on [π,2π]
    # also sort out normalisation
    @inbounds begin
        nm = n-1
        # fill in entries for ff on θ ∈ [π,2π)
        for j ∈ 1:nm
            ff[j] = real(fext[j+nm])
        end
        # fill in ff[2π] and normalise
        ff[n] = real(fext[1])
    end
    return nothing
end

end

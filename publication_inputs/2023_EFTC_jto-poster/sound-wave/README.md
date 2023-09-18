README
======

Setup
-----

The script in this directory uses James Cook's PlasmaDispersionFunctions.jl
package, as this is more accurate than a naive implementation of the plasma
dispersion function using SpecialFuncions.jl.

We also have to add the `moment_kinetics` package from the top level, which is
`../..` relative to this directory.

To set everything up, do
```julia
$ julia --project
julia>]
(2023_EFTC_jto-poster) pkg> add https://github.com/jwscook/PlasmaDispersionFunctions.jl
(2023_EFTC_jto-poster) pkg> dev ../..
(2023_EFTC_jto-poster) pkg>^D
$
```

Usage
-----

Import the script and run `make_plots()`
```
$ julia --project
julia> include("plot_dispersion_relation.jl")
julia> make_plots()
```
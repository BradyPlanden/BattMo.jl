# BattMo.jl is a framework for continuum modelling of lithium-ion batteries written in Julia


The Battery Modelling Toolbox (**BattMo**) is a resource for continuum modelling of electrochemical devices in MATLAB. The initial development features a pseudo X-dimensional (PXD) framework for the Doyle-Fuller-Newman model of lithium-ion battery cells. This is currently a early release that implements a subset of features from the [MATLAB version of BattMo](https://github.com/BattMoTeam/BattMo) with improved numerical performance. **BattMo.jl** is based on [Jutul.jl](https://github.com/sintefmath/Jutul.jl) and uses finite-volume discretizations and automatic differentiation to simulate models in 1D, 2D and 3D.

As a technology preview, the current implementation reads in input data prepared in the MATLAB version of BattMo, but the plan is to support a generic JSON input format that can be run in both codes.

<img src="docs/src/assets/battmologo_text.png" style="margin-left: 5cm" width="300px">

## Installation
This package is currently unregistered. To add it to your Julia environment, open Julia and run
```julia
using Pkg; Pkg.add(url="https://github.com/BattMoTeam/Battmo.jl")
```

### Getting started
For an example of usage, you can add the GLMakie plotting package:
```julia
using Pkg
Pkg.add("GLMakie")
```
You can then run the following to simulate the predefined `p2d_40` case:
```julia
using BattMo
# Simulate case
states, reports, extra, exported = run_battery("p2d_40");
# Plot result
using GLMakie
voltage = map(state -> state[:BPP][:Phi][1], states)
t = cumsum(extra[:timesteps])
fig = Figure()
ax = Axis(fig[1, 1], ylabel = "Voltage / V", xlabel = "Time / s", title = "Discharge curve")
lines!(ax, t, voltage)
display(fig)
```
This should produce the following plot:
![Discharge curve](docs/src/assets/discharge.png)


## Acknowledgements

BattMo has received funding from the European Union’s Horizon 2020 innovation program under grant agreement numbers:

* 875527 HYDRA  
* 957189 BIG-MAP  

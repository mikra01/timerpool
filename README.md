### timerpool library [![nimble](https://raw.githubusercontent.com/yglukhov/nimble-tag/master/nimble.png)](https://github.com/yglukhov/nimble-tag)
Thread-safe software timerpool implementation in Nim.

This library simplifies handling and running 
very much timers (constrained by memory).
The timers itself are not designed for 
critical time-measuring purposes. It´s for 
event purpose only

the module documentation can be found [here](https://mikra01.github.io/timerpool/timerpool.html) 

#### installation
nimble install timerpool

At the moment only tested on the windows10 platform with gcc/vcc (x64).

Comments, bug reports and PR´s always welcome.

to compile and run the tests type
"nimble test" within the projects main directory after cloning the repository. The tests
itself are not installed via the nimble installation


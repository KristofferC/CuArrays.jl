#' ---
#' title : A gentle introduction to parallelization and GPU programming in Julia
#' author : Tim Holy
#' date : 18th December 2018
#' ---

#' [Julia](https://julialang.org/) has first-class support for GPU programming:
#' you can use high-level abstractions or obtain fine-grained control, all without
#' ever leaving your favorite programming language.
#' The purpose of this tutorial is to help Julia users take their first step into
#' GPU computing.
#' In this tutorial, you'll compare CPU and GPU implementations of a simple
#' calculation, and learn about a few of the factors that influence the performance
#' you obtain.

#' This tutorial is inspired partly by a blog post by Mark Harris,
#' [An Even Easier Introduction to CUDA](https://devblogs.nvidia.com/even-easier-introduction-cuda/),
#' which introduced CUDA using the C++ programming language.
#' You do not need to read that tutorial, as this one starts from the beginning.

#' # A simple example on the CPU

#' We'll consider the following demo, a simple calculation on the CPU.

N = 2^20
x = fill(1.0f0, N)  # a vector filled with 1.0 (Float32)
y = fill(2.0f0, N)  # a vector filled with 2.0

y .+= x             # increment each element of y with the corresponding element of x

using Test
@test all(y .== 3.0f0)   # check that we got the right answer

#' From the `Test Passed` line we know everything is in order.
#' We used `Float32` numbers in preparation for the switch to GPU computations:
#' GPUs are faster (sometimes, much faster) when working with `Float32` than with `Float64`.

#' A distinguishing feature of this calculation is that every element of `y`
#' is being updated using the same operation.
#' This suggests that we might be able to parallelize this.

#' ## Parallelization on the CPU

#' First let's do the parallelization on the CPU.
#' We'll create a "kernel function" (the computational core of the algorithm)
#' in two implementations, one sequential and the other parallel:

# Sequential implementation
function sequential_add!(y, x)
    for i in eachindex(y, x)
        @inbounds y[i] += x[i]
    end
    return nothing
end

# Parallel implementation
function parallel_add!(y, x)
    Threads.@threads for i in eachindex(y, x)
        @inbounds y[i] += x[i]
    end
    return nothing
end

fill!(y, 2)
sequential_add!(y, x)
@test all(y .== 3.0f0)

fill!(y, 2)
parallel_add!(y, x)
@test all(y .== 3.0f0)

#' Now if I've started julia with `JULIA_NUM_THREADS=4` on a machine with at
#' least 4 cores, I get the following:

using BenchmarkTools
@btime sequential_add!($y, $x)

#' versus

@btime parallel_add!($y, $x)

#' You can see there's a performance benefit to parallelization, though not by
#' a full factor of 4 due to the overhead for starting threads.
#' With larger arrays, the overhead would be "diluted" by a larger amount of "real work";
#' these would demonstrate scaling that is closer to linear in the number of cores.
#' Conversely, with small arrays, the parallel version might be slower than
#' the serial version.

#' # Your first GPU computation

#' ## Installation

#' For most of this tutorial you need to have a computer with a
#' compatible GPU and have installed
#' [CUDA](https://developer.nvidia.com/cuda-downloads).
#' You should also install the following packages using Julia's [package manager](https://docs.julialang.org/en/latest/stdlib/Pkg/):

#' ```julia
#' pkg> add CUDAdrv CUDAnative CuArrays
#' ```

#' If this is your first time, it's not a bad idea to test whether your GPU is working:

#' ```julia
#' pkg> test CuArrays
#' ```

#' ## Parallelization on the GPU

#' We'll first demonstrate GPU computations at a high level, without
#' explicitly writing a kernel function:

using CuArrays, CUDAdrv

x_d = cufill(1.0f0, N)  # a vector stored on the GPU filled with 1.0 (Float32)
y_d = cufill(2.0f0, N)  # a vector stored on the GPU filled with 2.0

#' Here the `d` means "device," in contrast with "host."
#' Now let's do the increment:

y_d .+= x_d
@test all(Array(y_d) .== 3.0f0)

#' The statement `Array(y_d)` moves the data in `y_d` back to the host for testing.
#' If we want to benchmark this, let's put it in a function:

function add_broadcast!(y, x)
    y .+= x
    synchronize()
end

@btime add_broadcast!(y_d, x_d)

#' The most interesting part of this is the call to `synchronize`
#' from the `CUDAdrv` package.
#' The CPU can assign jobs to the GPU and then go do other stuff (such as assigning *more*
#' jobs to the GPU) while the GPU completes its tasks.
#' `synchronize` forces execution to pause until the queued tasks are done.
#' Without the `synchronize`, you'd be measuring the time takes to launch the computation,
#' not the time to perform the computation.

#' For this particular computer and GPU, you can see the GPU computation was significantly
#' faster than the single-threaded CPU computation, and that the use of CPU threads
#' makes the two competitive with one another.
#' Depending on your hardware you may get different results.

#' ## Writing your first GPU kernel

#' Using the high-level functionality of CuArrays made it easy to perform this
#' computation on the GPU.
#' However, we didn't learn about what's going on under the hood, and that's
#' the main goal of this tutorial.
#' So let's implement the same functionality with a GPU kernel.

function gpu_add1!(y, x)
    for i = 1:length(y)
        @inbounds y[i] += x[i]
    end
    return nothing
end

using CUDAnative

fill!(y_d, 2)
@cuda gpu_add1!(y_d, x_d)
@test all(Array(y_d) .== 3.0f0)

#' Aside from using the `CuArray`s `x_d` and `y_d`, the only GPU-specific part of this
#' is the *kernel launch* via `@cuda`, defined in the `CUDAnative` package.
#' The first time you issue this `@cuda` statement, it will compile the kernel
#' (`gpu_add1!`) for execution on the GPU.
#' Once compiled, future invocations are fast.
#' You can see what `@cuda` expands to using `?@cuda` from the Julia prompt.

#' Let's benchmark this:

function bench_gpu1!(y, x)
    @cuda gpu_add1!(y, x)
    synchronize()
end

@btime bench_gpu1!(y_d, x_d)

#' That's a *lot* slower than version above based on broadcasting. What happened?

#' ## Profiling

#' When you don't get the performance you expect, usually your first step should be
#' to profile the code and see where it's spending its time.
#' For that you'll need to be able to run NVIDIA's
#' [`nvprof` tool](https://devblogs.nvidia.com/cuda-pro-tip-nvprof-your-handy-universal-gpu-profiler/).
#' On Unix systems, launch Julia this way:
#' ```sh
#' $ nvprof --profile-from-start off /usr/local/bin/julia
#' ```
#' replacing the `/usr/local/bin/julia` with the path to your Julia binary.
#' After you've redefined all the necessary variables and methods, you can use

#' ```julia
#' julia> bench_gpu1!(y_d, x_d)  # run it once to force compilation
#' julia> CUDAdrv.@profile bench_gpu1!(y_d, x_d)
#' ```

#' and then quit Julia. I get output like this:
#' ```sh
#' ==21904== NVPROF is profiling process 21904, command: /usr/local/julia/julia-1.0/julia /tmp/tim/cuprofile.jl
#' ==21904== Profiling application: /usr/local/julia/julia-1.0/julia /tmp/tim/cuprofile.jl
#' ==21904== Profiling result:
#' Time(%)      Time     Calls       Avg       Min       Max  Name
#' 100.00%  357.39ms         1  357.39ms  357.39ms  357.39ms  ptxcall_gpu_add1__1
#'
#' ==21904== API calls:
#' Time(%)      Time     Calls       Avg       Min       Max  Name
#'  99.56%  357.39ms         1  357.39ms  357.39ms  357.39ms  cuCtxSynchronize
#'   0.30%  1.0910ms         1  1.0910ms  1.0910ms  1.0910ms  cuLaunchKernel
#'   0.13%  481.99us         2  241.00us     610ns  481.38us  cuCtxGetCurrent
#' ```

#' You can see that 100% of the time was spent in `ptxcall_gpu_add1__1`,
#' the name of the kernel that `CUDAnative` assigned when compiling `gpu_add1!`
#' for these inputs.
#' (Had you created arrays of multiple data types, e.g., `xu_d = cufill(0x01, N)`,
#' you might have also seen `ptxcall_gpu_add1__2` and so on.
#' Like the rest of Julia, you can define a single method and it will be specialized
#' at compile time for the particular data types you're using.)

#' For further insight, run the profiling with the option
#' ```julia
#' $ nvprof --profile-from-start off --print-gpu-trace /usr/local/bin/julia /tmp/cuprofile.jl
#' ```
#' where here I've put all the commands I want to run (including the `CUDAdrv.@profile`)
#' into a script `/tmp/cuprofile.jl`.
#' Then I see
#' ```sh
#' ==24101== NVPROF is profiling process 24101, command: /usr/local/julia/julia-1.0/julia /tmp/tim/cuprofile.jl
#' ==24101== Profiling application: /usr/local/julia/julia-1.0/julia /tmp/tim/cuprofile.jl
#' ==24101== Profiling result:
#'    Start  Duration            Grid Size      Block Size     Regs*    SSMem*    DSMem*      Size  Throughput           Device   Context    Stream  Name
#' 19.9962s  357.72ms              (1 1 1)         (1 1 1)        19        0B        0B         -           -   Tesla K20c (0)         1         7  ptxcall_gpu_add1__1 [27]
#'
#' Regs: Number of registers used per CUDA thread. This number includes registers used internally by the CUDA driver and/or tools and can be more than what the compiler shows.
#' SSMem: Static shared memory allocated per CUDA block.
#' DSMem: Dynamic shared memory allocated per CUDA block.
#' ```

#' The key thing to note here is the `(1 1 1)` in the "Grid Size" and "Block Size" columns.
#' These terms will be explained shortly, but for now suffice it to
#' say that this is an indication that this computation ran
#' sequentially.
#' Of note, sequential processing with GPUs is much slower than with CPUs; where
#' GPUs shine is with large-scale parallelism.

#' ## Writing a parallel GPU kernel

#' To speed up the kernel, we want to parallelize it, which means assigning different
#' tasks to different threads.  To facilitate the assignment of work, each CUDA
#' thread gets access to variables that indicate its own unique identity, much as
#' [`Threads.threadid()`](https://docs.julialang.org/en/latest/manual/parallel-computing/#Multi-Threading-(Experimental)-1)
#' does for CPU threads.
#' The CUDA analogs of `threadid` and `nthreads` are called `threadIdx` and `blockDim`,
#' respectively; one difference is that these return a 3-dimensional structure with
#' fields `x`, `y`, and `z` to simplify cartesian indexing for up to 3-dimensional arrays.
#' Consequently we can assign unique work in the following way:

function gpu_add2!(y, x)
    index = threadIdx().x    # this example only requires linear indexing, so just use `x`
    stride = blockDim().x
    for i = index:stride:length(y)
        @inbounds y[i] += x[i]
    end
    return nothing
end

fill!(y_d, 2)
@cuda threads=256 gpu_add2!(y_d, x_d)
@test all(Array(y_d) .== 3.0f0)

#' Note the `threads=256` here, which divides the work among 256 threads numbered in a
#' linear pattern. (For a two dimensional array, we might have used `threads=(16, 16)`
#' and then both `x` and `y` would be relevant.)

#' Now let's try benchmarking it:

function bench_gpu2!(y, x)
    @cuda threads=256 gpu_add2!(y, x)
    synchronize()
end

@btime bench_gpu2!(y_d, x_d)

#' Much better!

#' But obviously we still have a ways to go to match the initial broadcasting result.
#' To do even better, we need to parallelize more. GPUs have a limited number of threads
#' they can run on a single *streaming multiprocessor* (SM), but they also have
#' multiple SMs.
#' To take advantage of them all, we need to run a kernel with multiple *blocks*.
#' We'll divide up the work like this:
#' ![block grid](intro1.png)
#' Note that this diagram was
#' [borrowed from a description of the C/C++ libary](https://devblogs.nvidia.com/even-easier-introduction-cuda/);
#' in Julia, threads and blocks begin numbering with 1 instead of 0.
#' In this diagram, the 4096 blocks of 256 threads (making 1048576 = 2^20 threads) ensures
#' that each thread increments just a single entry; however, to ensure that arrays
#' of arbitrary size can be handled, let's still use a loop:

function gpu_add3!(y, x)
    index = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    stride = blockDim().x * gridDim().x
    for i = index:stride:length(y)
        @inbounds y[i] += x[i]
    end
    return nothing
end

numblocks = ceil(Int, N/256)

fill!(y_d, 2)
@cuda threads=256 blocks=numblocks gpu_add3!(y_d, x_d)
@test all(Array(y_d) .== 3.0f0)

#' The benchmark:

function bench_gpu3!(y, x)
    numblocks = ceil(Int, length(y)/256)
    @cuda threads=256 blocks=numblocks gpu_add3!(y, x)
    synchronize()
end

@btime bench_gpu3!(y_d, x_d)

#' Finally, we've achieved the similar performance to what we got with the
#' broadcasted version.
#' If you use `nvprof` here, you should see a line like

#' ```sh
#' 22.1926s  122.56us           (4096 1 1)       (256 1 1)        32        0B        0B         -           -   Tesla K20c (0)         1         7  ptxcall_gpu_add3__3 [67]
#' ```

#' demonstrating this this computation used multiple blocks and threads.

#' ## Printing

#' When debugging, it's not uncommon to want to print some values.
#' This is achieved with `@cuprintf`:

function gpu_add2_print!(y, x)
    index = threadIdx().x    # this example only requires linear indexing, so just use `x`
    stride = blockDim().x
    @cuprintf("threadIdx %ld, blockDim %ld\n", index, stride)
    for i = index:stride:length(y)
        @inbounds y[i] += x[i]
    end
    return nothing
end

@cuda threads=16 gpu_add2_print!(y_d, x_d)
synchronize()

#' Note that the printed output is generated when running `synchronize`.

#' ## Error-handling

#' The final topic of this intro concerns the handling of errors.
#' Note that the kernels above used `@inbounds`, but did not check whether `y` and
#' `x` have the same length. If they don't, you can get errors like this:
#' ```julia
#' ERROR: CUDA error: an illegal memory access was encountered (code #700, ERROR_ILLEGAL_ADDRESS)
#' Stacktrace:
#'  [1] macro expansion at /home/tim/.julia/dev/CUDAdrv/src/base.jl:147 [inlined]
#'  [2] synchronize(::CuContext) at /home/tim/.julia/dev/CUDAdrv/src/context.jl:183 (repeats 2 times)
#'  [3] top-level scope at none:0
#' ```
#'
#' If you remove the `@inbounds` annotation, instead you get
#'
#' ```julia
#' ERROR: a boundserror exception occurred during kernel execution
#' Error During Test at REPL[14]:1
#'   Test threw exception
#'   Expression: all(Array(y_d) .== 3.0f0)
#'   CUDA error: an illegal instruction was encountered (code #715, ERROR_ILLEGAL_INSTRUCTION)
#'   Stacktrace:
#'    [1] #download!#11(::Bool, ::Function, ::Ptr{Float32}, ::CUDAdrv.Mem.Buffer, ::Int64, ::CuStream) at /home/tim/.julia/dev/CUDAdrv/src/memory.jl:254
#'    [2] download! at /home/tim/.julia/dev/CUDAdrv/src/memory.jl:248 [inlined] (repeats 2 times)
#'    [3] unsafe_copyto! at /home/tim/.julia/dev/CuArrays/src/array.jl:166 [inlined]
#'    [4] copyto! at /home/tim/.julia/packages/GPUArrays/HmVTY/src/abstractarray.jl:110 [inlined]
#'    [5] Array{Float32,1}(::CuArray{Float32,1}) at ./array.jl:497
#'    [6] Array(::CuArray{Float32,1}) at ./boot.jl:418
#'    [7] top-level scope at none:0
#'    [8] eval(::Module, ::Any) at ./boot.jl:319
#'    [9] eval_user_input(::Any, ::REPL.REPLBackend) at /usr/local/julia/julia-1.0/usr/share/julia/stdlib/v1.0/REPL/src/REPL.jl:85
#'    [10] run_backend(::REPL.REPLBackend) at /home/tim/.julia/packages/Revise/gStbk/src/Revise.jl:771
#'    [11] (::getfield(Revise, Symbol("##58#60")){REPL.REPLBackend})() at ./task.jl:259
#' ERROR: There was an error during testing
#' ```
#'
#' If you want the performance advantage of `@inbounds` but want to use it more safely,
#' you can do manual bounds-checks:

function gpu_add1_safe!(y, x)
    size(y) == size(x) || throw(CUDAdrv.ERROR_ILLEGAL_ADDRESS)
    for i = 1:length(y)
        @inbounds y[i] += x[i]
    end
    return nothing
end

#' Any errors typically corrupt the CUDA context, and require you to restart Julia.
#' As a consequence, it's often a good idea to perform your "sanity checks" using
#' code that runs on the CPU, and only turn over the computation to the GPU once
#' you've deemed it to be safe.

#' # Summary

#' Keep in mind that
#' the high-level functionality of CuArrays often means that you don't need to worry
#' about writing kernels at such a low level. However, there are many cases
#' where computations can be optimized using clever low-level manipulations.
#' Hopefully, you now feel comfortable taking the plunge

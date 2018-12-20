JULIA_NUM_THREADS=4 julia -e 'using Weave; weave("intro.jl", out_path="../build/", doctype="md2html")'

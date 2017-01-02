__precompile__()

module Polynomials

    export vandermonde_matrix, vandermonde_matrix_inverse

    include("polynomials/vandermonde_matrix.jl")

    export LagrangePolynomial, similar, evaluate!

    include("polynomials/lagrange_polynomials.jl")

end

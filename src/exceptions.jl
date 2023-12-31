mutable struct ModelNotFitted <: Exception end
Base.showerror(io::IO, e::ModelNotFitted) = print(io, "The model has not been fitted yet. Please run fit!(model)")

mutable struct MissingMethodImplementation <: Exception 
    method::String
end
Base.showerror(io::IO, e::MissingMethodImplementation) = print(io, "The model does not implement the ", e.method, " method.")


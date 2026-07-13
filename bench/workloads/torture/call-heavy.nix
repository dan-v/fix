# Call/thunk-bound: naive recursive Fibonacci.
#
# Exponential call tree, no data structures — this is almost pure function
# application, argument thunk allocation, and integer comparison/addition.
# Isolates the evaluator's call/return + thunk machinery.
#
# fib 30 => 832040, ~2.7M calls.
let
  fib = n: if n < 2 then n else fib (n - 1) + fib (n - 2);
in
  fib 30

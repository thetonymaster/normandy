# Normandy.Type.dump/2 on the scalar types whose clauses call the inlined same_*
# helpers (lib/normandy/type.ex, `@compile {:inline, ...}`), and on a 1k array.
# Settles principles audit schema#10: save on HEAD, delete the directive on a scratch
# branch, compare (bench/README.md).
Code.require_file("support.exs", __DIR__)

alias Bench.Support
alias Normandy.Type

# Before any setup, so a bad BENCH_SAVE/BENCH_COMPARE fails at once.
opts = Support.run_opts("type_dump")

array = Enum.to_list(1..1_000)

values = [
  integer: 42,
  boolean: true,
  map: %{"a" => 1},
  string: "hello",
  binary: <<1, 2, 3>>,
  date: ~D[2026-10-23],
  duration: Duration.new!(minute: 5)
]

for {type, value} <- values do
  Support.assert!(
    Type.dump(type, value) == {:ok, value},
    "dump #{inspect(type)} must return {:ok, value}"
  )
end

Support.assert!(
  Type.dump({:array, :integer}, array) == {:ok, array},
  "dump of the 1k array must succeed"
)

Support.assert!(
  Type.cast({:array, :integer}, array) == {:ok, array},
  "cast of the 1k array must succeed"
)

Support.banner(
  "Normandy.Type.dump/2 (inlined same_* helpers)",
  ["one value per scalar type", "{:array, :integer} of 1k"],
  "constant per scalar; linear in the array. Compare with the @compile {:inline} " <>
    "at lib/normandy/type.ex removed (see bench/README.md)"
)

# One scalar dump takes a few ns, under Benchee's reliable resolution, so each scalar
# scenario times 1000 calls; "loop x1000 baseline" is the loop alone, to subtract.
scalar_jobs =
  Map.new(values, fn {type, value} ->
    {"dump #{inspect(type)} x1000",
     fn -> Enum.each(1..1_000, fn _ -> Type.dump(type, value) end) end}
  end)

jobs =
  Map.merge(scalar_jobs, %{
    "loop x1000 baseline" => fn -> Enum.each(1..1_000, fn _ -> {:ok, array} end) end,
    "dump {:array, :integer} 1k" => fn -> Type.dump({:array, :integer}, array) end,
    "cast :integer x1000" => fn -> Enum.each(1..1_000, fn _ -> Type.cast(:integer, 42) end) end,
    "cast {:array, :integer} 1k" => fn -> Type.cast({:array, :integer}, array) end
  })

Benchee.run(jobs, opts)

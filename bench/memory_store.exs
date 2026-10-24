# MemoryStore backends (Mnesia, Redis, Postgres; InMemory and ETS as in-process
# baselines): writing a new document under limits, reading one, and listing a
# namespace of 100. Redis and Postgres must be reachable (bench/README.md) or left out
# with BENCH_STORES.
Code.require_file("support.exs", __DIR__)
Code.require_file("support/store_backends.exs", __DIR__)

alias Bench.StoreBackends
alias Bench.Support

documents = 100
content = String.duplicate("m", 1_024)
# High enough that the overwritten document never fills the namespace.
limits = [max_bytes: 100_000_000, max_documents: 1_000_000]
backends = StoreBackends.selected()

try do
  stores =
    Map.new(backends, fn backend ->
      {mod, h} = store = StoreBackends.memory_store(backend)
      ns = StoreBackends.track_namespace(store, "bench_#{UUID.uuid4()}")

      for i <- 1..documents,
          do: {:ok, 1} = mod.put(h, ns, "/memories/doc_#{i}.md", content, :new, limits)

      {backend, {mod, h, ns}}
    end)

  for {backend, {mod, h, ns}} <- stores do
    Support.assert!(
      match?({:ok, %{content: ^content, version: 1}}, mod.get(h, ns, "/memories/doc_1.md")),
      "#{backend} get must return the stored document"
    )

    {:ok, listed} = mod.list(h, ns, "/memories")

    Support.assert!(
      length(listed) == documents,
      "#{backend} list must return #{documents} documents"
    )
  end

  Support.banner(
    "MemoryStore backends: #{Enum.join(backends, ", ")}",
    ["#{documents} documents of 1 KB per namespace"],
    "constant per call except list (linear in documents); Redis and Postgres add a round trip"
  )

  jobs =
    for {backend, {mod, h, ns}} <- stores, reduce: %{} do
      jobs ->
        Map.merge(jobs, %{
          # Overwrites one document: a fresh path per call wrote ~100 MB a second on the
          # in-process backends and grew the namespace under the other scenarios.
          "#{backend} put" => fn ->
            {:ok, _version} = mod.put(h, ns, "/scratch/doc.md", content, :any, limits)
          end,
          "#{backend} get" => fn -> {:ok, _} = mod.get(h, ns, "/memories/doc_1.md") end,
          "#{backend} list" => fn -> {:ok, _} = mod.list(h, ns, "/memories") end
        })
    end

  Benchee.run(jobs, Support.run_opts("memory_store"))
after
  StoreBackends.cleanup!()
end

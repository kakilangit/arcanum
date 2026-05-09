%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      checks: [
        {Credo.Check.Refactor.Nesting, max_nesting: 2}
      ]
    }
  ]
}

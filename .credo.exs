%{
  configs: [
    %{
      name: "default",
      plugins: [{ExSlop, []}],
      checks: %{
        extra: [
          {ExSlop.Check.Refactor.CaseTrueFalse, []},
          {ExSlop.Check.Refactor.UseMapJoin, []},
          {ExSlop.Check.Refactor.PreferEnumSlice, []},
          {ExSlop.Check.Refactor.ListFold, []},
          {ExSlop.Check.Refactor.ListLast, []},
          {ExSlop.Check.Refactor.LengthInGuard, []},
          {ExSlop.Check.Readability.DocFalseOnPublicFunction, []},
          {ExSlop.Check.Readability.ObviousComment, [additional_keywords: []]},
          {ExSlop.Check.Readability.StepComment, []},
          {ExSlop.Check.Readability.UnaliasedModuleUse, []}
        ]
      }
    }
  ]
}

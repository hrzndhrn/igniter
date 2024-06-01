defmodule Igniter.Install do
  @option_schema [
    switches: [
      no_network: :boolean,
      example: :boolean,
      dry_run: :boolean
    ],
    aliases: [
      d: :dry_run,
      n: :no_network,
      e: :example
    ]
  ]

  # only supports hex installation at the moment
  def install(install, argv) do
    install_list =
      install
      |> String.split(",")
      |> Enum.map(&String.to_atom/1)

    Application.ensure_all_started(:req)

    {options, _} =
      OptionParser.parse!(argv, @option_schema)

    argv = OptionParser.to_argv(options)

    igniter = Igniter.new()

    igniter =
      Enum.reduce(install_list, igniter, fn install, igniter ->
        if Mix.Project.config()[:deps][install][:path] do
          Mix.shell().info(
            "Not looking up dependency for #{install}, because a local dependency is detected"
          )

          igniter
        else
          case Req.get!("https://hex.pm/api/packages/#{install}").body do
            %{
              "releases" => [
                %{"version" => version}
                | _
              ]
            } ->
              requirement =
                version
                |> Version.parse!()
                |> case do
                  %Version{major: 0, minor: minor} ->
                    "~> 0.#{minor}"

                  %Version{major: major} ->
                    "~> #{major}.0"
                end

              Igniter.Deps.add_dependency(igniter, install, requirement)

            _ ->
              Igniter.add_issue(igniter, "No published versions of #{install} on hex")
          end
        end
      end)

    confirmation_message =
      unless options[:dry_run] do
        "Dependencies changes must go into effect before individual installers can be run. Proceed with changes?"
      end

    dependency_add_result =
      Igniter.Tasks.do_or_dry_run(igniter, argv,
        title: "Fetching Dependency",
        quiet_on_no_changes?: true,
        confirmation_message: confirmation_message
      )

    if dependency_add_result == :issues do
      raise "Exiting due to issues found while fetching dependency"
    end

    if dependency_add_result == :dry_run_with_changes do
      install_dep_now? =
        Mix.shell().yes?("""
        Cannot run any associated installers for the requested packages without
        commiting changes and fetching dependencies.

        Would you like to do so now? The remaining steps will be displayed as a dry run.
        """)

      if install_dep_now? do
        Igniter.Tasks.do_or_dry_run(igniter, (argv ++ ["--yes"]) -- ["--dry-run"],
          title: "Fetching Dependency",
          quiet_on_no_changes?: true
        )
      end
    end

    Mix.shell().info("running mix deps.get")

    case Mix.shell().cmd("mix deps.get") do
      0 ->
        Mix.Task.reenable("compile")
        Mix.Task.run("compile")

      exit_code ->
        Mix.shell().info("""
        mix deps.get returned exited with code: `#{exit_code}`
        """)
    end

    all_tasks =
      Enum.filter(Mix.Task.load_all(), &Spark.implements_behaviour?(&1, Igniter.Mix.Task))

    install_list
    |> Enum.flat_map(fn install ->
      all_tasks
      |> Enum.find(fn task ->
        Mix.Task.task_name(task) == "#{install}.install"
      end)
      |> List.wrap()
    end)
    |> Enum.reduce(Igniter.new(), fn task, igniter ->
      Igniter.compose_task(igniter, task, argv)
    end)
    |> Igniter.Tasks.do_or_dry_run(argv)

    :ok
  end
end

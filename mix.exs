defmodule NxHailo.MixProject do
  use Mix.Project

  @app :nx_hailo
  @version "0.1.0"
  @all_targets [:rpi5]

  # Models to download at compile time. Each HEF is ~40-100 MB.
  #
  # Use a bare atom for models in the default hailo8l zoo (v2.15.0):
  #   :yolov8m, :yolov8n, :yolov8s, :yolov8l, :yolov8x,
  #   :yolov8s_pose, :yolov8m_pose
  #
  # Use a {name, url} tuple for models with a non-standard download URL:
  #   {:resnet_v1_50, "https://...hailo8/resnet_v1_50.hef"}
  @models_to_download [:yolov8m]

  @zoo_version "v2.15.0"
  @zoo_base "https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/#{@zoo_version}/hailo8l"
  @coco_dataset_yml "https://raw.githubusercontent.com/ultralytics/ultralytics/refs/heads/main/ultralytics/cfg/datasets/coco.yaml"
  @imagenet_classes_txt "https://raw.githubusercontent.com/pytorch/hub/master/imagenet_classes.txt"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      archives: [nerves_bootstrap: "~> 1.13.1"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: [{@app, release()}],
      preferred_cli_target: [run: :host, test: :host],
      compilers: [:download_models, :elixir_make] ++ Mix.compilers(),
      make_env: fn ->
        %{
          "MIX_BUILD_EMBEDDED" => "#{Mix.Project.config()[:build_embedded]}",
          "FINE_INCLUDE_DIR" => Fine.include_dir()
        }
      end
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},

      {:evision, "~> 0.2"},
      {:exla, "~> 0.10.0"},
      {:bandit, "~> 1.5"},
      {:nx, "~> 0.6"},
      {:elixir_make, "~> 0.6", runtime: false},
      {:fine, "~> 0.1.0", runtime: false},
      {:req, "~> 0.5.10", runtime: false, optional: true},
      {:yaml_elixir, "~> 2.10"},

      # Deps for running the livebook demo
      {:kino, "~> 0.14"}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"],
      "compile.download_models": [&download_models/1]
    ]
  end

  defp download_models(_args) do
    {:ok, _} = Application.ensure_all_started([:req])

    priv = Path.join(__DIR__, "priv")
    File.mkdir_p!(priv)

    download_dataset_to_json_file(@coco_dataset_yml, Path.join(priv, "coco_classes.json"))
    download_text_classes_to_json_file(@imagenet_classes_txt, Path.join(priv, "imagenet_classes.json"))

    for model <- @models_to_download do
      {name, url} =
        case model do
          {name, url} -> {name, url}
          name when is_atom(name) -> {name, "#{@zoo_base}/#{name}.hef"}
        end

      download_model(url, Path.join(priv, "#{name}.hef"))
    end
  end

  defp download_text_classes_to_json_file(url, filename) do
    if File.exists?(filename) do
      :ok
    else
      %{body: text} = Req.get!(url)

      contents =
        text
        |> String.split("\n", trim: true)
        |> Jason.encode!()

      File.write!(filename, contents)
    end
  end

  defp download_dataset_to_json_file(url, filename) do
    if File.exists?(filename) do
      :ok
    else
      %{body: yaml_contents} = Req.get!(url)

      contents =
        yaml_contents
        |> YamlElixir.read_from_string!()
        |> Map.get("names")
        |> Enum.sort_by(fn {index, _name} -> index end)
        |> Enum.map(fn {_index, name} -> name end)
        |> Jason.encode!()

      File.write!(filename, contents)
    end
  end

  defp download_model(url, filename) do
    marker_filename = filename <> ".marker"

    if File.exists?(marker_filename) do
      IO.puts("Model already exists: #{filename}. Skipping download.")
      :ok
    else
      IO.puts("Model does not exist: #{filename}. Downloading...")
      %{headers: headers, body: response_body} = Req.get!(url)

      if "application/zip" in headers["content-type"] do
        for {output_filename, contents} <- response_body do
          File.write!(Path.join(Path.dirname(filename), to_string(output_filename)), contents)
        end
      else
        File.write!(filename, response_body)
      end

      File.write!(marker_filename, "")
    end
  end
end

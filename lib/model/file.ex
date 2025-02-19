defmodule Model.File do
  def load(filename, default \\ nil) do
    case File.read(filename) do
      {:ok, content} ->
        BertInt.decode!(content)

      {:error, _} ->
        case default do
          fun when is_function(fun) -> fun.()
          _ -> default
        end
    end
  end

  def store(filename, term, overwrite \\ false) do
    if overwrite or not File.exists?(filename) do
      content = BertInt.encode!(term)

      with :ok <- File.mkdir_p(Path.dirname(filename)) do
        tmp = "#{filename}.#{:erlang.phash2(self())}"
        File.write!(tmp, content)
        File.rename!(tmp, filename)
      end
    end

    term
  end
end

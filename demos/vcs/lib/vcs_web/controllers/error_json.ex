defmodule VcsWeb.ErrorJSON do
  @moduledoc "Terse JSON errors. A CLI is the only client, so there is nothing to render."

  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end
end

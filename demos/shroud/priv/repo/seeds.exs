# Seeds.
#
#     mix run priv/repo/seeds.exs
#
# Note what can and cannot be seeded, because the boundary is the app's whole thesis.
#
# **Public posts can be.** They are plaintext by design, so the server can write them
# just as it can read them. That is not a loophole — it is the definition of Tier 0.
#
# **Private posts and profile details cannot.** They need a master key, and master keys
# exist only inside a browser. There is no server-side path to create readable private
# data, so there is no server-side path to seed it either. If this script could seed an
# encrypted post, the encryption would be worthless.
#
# So a fresh install gets a populated public timeline and some people to add to an
# audience, and everything private has to be created by a real signed-in user.

require Ash.Query

alias Shroud.Global.User
alias Shroud.Profiles

people = [
  {"ada",
   [
     "The Analytical Engine has no pretensions whatever to originate anything.",
     "Spent the morning on Note G. It works."
   ]},
  {"grace",
   [
     "Shipped the compiler. It is easier to apologise than to get permission.",
     "A ship in port is safe, but that is not what ships are built for."
   ]},
  {"edsger",
   [
     "Simplicity is a great virtue but it requires hard work to achieve it.",
     "Testing shows the presence, not the absence of bugs."
   ]},
  {"barbara", ["Spent thirty years being told the maize was wrong. It was not the maize."]}
]

for {handle, posts} <- people do
  user =
    case Ash.read_one!(Ash.Query.filter(User, handle == ^handle)) do
      nil ->
        # A real public key, so sealing to them works. The matching private key is
        # discarded on purpose: nothing sealed to these fixtures is ever readable, which
        # is a reminder that a lost key is not a recoverable situation.
        {public_key, _private_key} = Shroud.Sealing.generate_keypair()
        IO.puts("seeded @#{handle}")
        Ash.create!(User, %{handle: handle, public_key: public_key}, action: :register)

      existing ->
        existing
    end

  existing_count =
    Shroud.Global.PostRef
    |> Ash.Query.filter(author_id == ^user.id)
    |> Ash.read!()
    |> length()

  if existing_count == 0 do
    for body <- posts do
      {:ok, _} = Profiles.publish_post(user.id, %{visibility: "public", body: body})
    end

    IO.puts("  #{length(posts)} public posts")
  end
end

IO.puts("""

Seeded. These accounts have no passkeys, so they cannot sign in — they exist to give you
somebody to add to an audience and a timeline that is not empty. Register your own
account to create anything encrypted.
""")

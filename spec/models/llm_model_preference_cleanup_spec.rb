require "rails_helper"

# Favourites and default-model settings hold meta_ids as bare strings, with no
# foreign key behind them. Deleting a model used to leave those pointing at
# nothing: the entry stayed in the user's list, matched no model, and silently
# stopped rendering — which reads as "my model disappeared from the picker".
# This happened for real on 2026-09-04 when 11 retired models were deleted.
RSpec.describe LlmModel, "user-preference cleanup on destroy" do
  let(:llm) { Llm.find_or_create_by!(family: "openai") { |l| l.name = "Openai" } }
  let(:model) do
    llm.llm_models.create!(name: "doomed-1", api_id: "doomed.1", display_name: "Doomed One",
                           pricing: { "input" => 1.0, "output" => 2.0 })
  end
  let(:user) do
    User.create!(email: "fav@example.com", google_id: "g-fav",
                 favorite_model_meta_ids: [ "keeper-1", "doomed-1", "keeper-2" ])
  end

  it "removes the model from every user's favourites" do
    user

    model.destroy!

    expect(user.reload.favorite_model_meta_ids).to eq([ "keeper-1", "keeper-2" ])
  end

  it "leaves users who never favourited it alone" do
    other = User.create!(email: "other@example.com", google_id: "g-other",
                         favorite_model_meta_ids: [ "keeper-1" ])

    model.destroy!

    expect(other.reload.favorite_model_meta_ids).to eq([ "keeper-1" ])
  end

  it "clears the model from anyone whose default it was" do
    user.update!(default_model_meta_id: "doomed-1")

    model.destroy!

    expect(user.reload.default_model_meta_id).to be_nil
  end

  it "leaves a different default alone" do
    user.update!(default_model_meta_id: "keeper-1")

    model.destroy!

    expect(user.reload.default_model_meta_id).to eq("keeper-1")
  end

  # Reversed 2026-09-12. Hiding used to preserve preferences on the theory
  # that it was reversible, but retirement is one-way in practice and a
  # favourite pointing at a hidden model silently renders nothing — the user
  # just sees a shorter picker with no explanation. The trade-off accepted
  # here is that re-activating a model no longer restores anyone's favourite.
  it "purges when the model is retired, not only when it is deleted" do
    user

    model.update!(active: false)

    expect(user.reload.favorite_model_meta_ids).to eq([ "keeper-1", "keeper-2" ])
  end

  it "does not purge on an unrelated edit" do
    user

    model.update!(position: 42)

    expect(user.reload.favorite_model_meta_ids).to include("doomed-1")
  end

  # Closes a surviving mutant: a guard of `!active?` alone (without the
  # transition check) would re-purge every time an already-hidden model is
  # edited at all, so the hook has to fire on the change, not on the state.
  it "does not purge again when an already-retired model is edited" do
    model.update!(active: false)
    later = User.create!(email: "again@example.com", google_id: "g-again",
                         favorite_model_meta_ids: [ "doomed-1" ])

    model.update!(notes: "retired, kept for the record")

    expect(later.reload.favorite_model_meta_ids).to eq([ "doomed-1" ])
  end

  it "does not purge when a hidden model is brought back" do
    model.update!(active: false)
    other = User.create!(email: "later@example.com", google_id: "g-later",
                         favorite_model_meta_ids: [ "doomed-1" ])

    model.update!(active: true)

    expect(other.reload.favorite_model_meta_ids).to eq([ "doomed-1" ])
  end

  describe ".prune_stale_user_preferences (backlog cleanup)" do
    it "clears references to models that were retired before the hook existed" do
      model.update_columns(active: false) # bypasses the callback, as history did
      user

      expect(described_class.prune_stale_user_preferences).to eq(1)
      expect(user.reload.favorite_model_meta_ids).to eq([])
    end

    it "keeps references to models that are still served" do
      live = llm.llm_models.create!(name: "keeper-1", api_id: "keeper.1",
                                    display_name: "Keeper One",
                                    pricing: { "input" => 1.0, "output" => 2.0 })
      user.update!(favorite_model_meta_ids: [ live.name ])

      described_class.prune_stale_user_preferences

      expect(user.reload.favorite_model_meta_ids).to eq([ "keeper-1" ])
    end

    it "clears a default pointing at a retired model" do
      model.update_columns(active: false)
      user.update!(default_model_meta_id: "doomed-1")

      described_class.prune_stale_user_preferences

      expect(user.reload.default_model_meta_id).to be_nil
    end

    it "is idempotent" do
      model.update_columns(active: false)
      user

      described_class.prune_stale_user_preferences
      expect(described_class.prune_stale_user_preferences).to eq(0)
    end
  end

  it "reports how many users it touched" do
    user.update!(default_model_meta_id: "doomed-1")

    # Once for the default, once for the favourites list.
    expect(model.purge_from_user_preferences).to eq(2)
  end
end

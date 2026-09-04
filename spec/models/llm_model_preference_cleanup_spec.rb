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

  it "does NOT purge when the model is merely hidden — hiding is reversible" do
    user

    model.update!(active: false)

    expect(user.reload.favorite_model_meta_ids).to include("doomed-1")
  end

  it "reports how many users it touched" do
    user.update!(default_model_meta_id: "doomed-1")

    # Once for the default, once for the favourites list.
    expect(model.purge_from_user_preferences).to eq(2)
  end
end

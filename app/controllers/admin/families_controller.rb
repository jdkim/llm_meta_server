# frozen_string_literal: true

module Admin
  # Creating a provider family.
  #
  # Models have been curatable here since the catalog moved into the database,
  # but a brand-new provider could still only arrive through CatalogSeeder —
  # the one place that creates Llm rows. That made adding one provider mean
  # reseeding, which forces `active: true` across the whole checked-in catalog
  # and so overwrites unrelated curation. This closes that gap.
  class FamiliesController < BaseController
    def create
      family = params[:family].to_s.strip.downcase

      unless Llm.addable_families.include?(family)
        return redirect_to admin_models_path,
                           alert: "Cannot add #{family.presence || 'a blank provider'} — " \
                                  "either this server has no client for it, or it already exists"
      end

      # Same naming the seeder uses, so a family created here and one restored
      # from the catalog are indistinguishable.
      Llm.create!(family: family, name: family.capitalize)
      redirect_to admin_models_path, notice: "Added provider #{family} — add its models next"
    end
  end
end

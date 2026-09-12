# The model exists in the catalog, just not in the family this request was
# allowed to look in.
#
# Raised instead of ModelNotFoundError because the two mean different things
# and the difference is what a user needs to act on. "Not found" sends people
# to the catalog; this one means the request arrived without a resolved
# provider key — almost always an expired session — while the model itself is
# perfectly fine.
class ModelUnavailableError < StandardError
  attr_reader :model_name, :family

  def initialize(model_name, family)
    @model_name = model_name
    @family = family
    super("#{model_name} requires an API key for #{family}, and this request " \
          "had none. Your session may have expired — reload the page and try again.")
  end
end
